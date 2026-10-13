import Foundation

/// Owns every state transition: when to probe, when to sign in, when to give up.
///
/// The rule everything else bends around: credentials are sent only when the probe
/// that has just completed returned `.vitPortal`.
actor MatchEngine {
    struct Timing: Sendable {
        /// Time for DHCP and DNS to settle after Wi-Fi comes up.
        var settleDelay: Duration = .milliseconds(1500)
        var probeTimeout: Duration = .milliseconds(3500)
        /// Waits before each probe-only retry after a probe error.
        var probeRetryDelays: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]
        /// Probes made after a successful sign-in, waiting for the internet to open up.
        var revalidationAttempts = 3
        var revalidationDelay: Duration = .seconds(2)
        var gatewayCheckTimeout: Duration = .seconds(2)
        /// While in a failed state, how long before first looking again, and how
        /// often after that. These looks are probes only.
        var firstRecoveryCheck: Duration = .seconds(10)
        var recoveryCheckInterval: Duration = .seconds(60)
    }

    /// What asked for a check. Ordered so that merging two requests keeps the stronger.
    private enum Trigger: Int, Comparable {
        case automatic
        case sessionExpired
        case user

        static func < (lhs: Trigger, rhs: Trigger) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private struct Network: Equatable {
        var interface: String
        var gateway: String?

        /// A gateway that is not known yet does not make it a different network.
        func isSameNetwork(as other: Network) -> Bool {
            guard interface == other.interface else { return false }
            guard let gateway, let otherGateway = other.gateway else { return true }
            return gateway == otherGateway
        }
    }

    private struct Request {
        var trigger: Trigger
        var settle: Duration?
    }

    private let detector: PortalDetector
    private let client: ProntoClient
    private let credentials: any CredentialStore
    private let settings: any EngineSettings
    private let notifier: any Notifying
    private let sessions: any SessionRecording
    private let networkNames: any NetworkNaming
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let timing: Timing
    private let healthChecker: HealthChecker

    private(set) var state: EngineState = .noWiFi
    private var subscribers: [UUID: AsyncStream<EngineState>.Continuation] = [:]

    private var network: Network?
    private var autoLoginEnabled: Bool
    private var suppressAutoLoginUntilNextNetworkChange = false
    /// Set when the portal rejected the saved credentials. Until the user acts, no
    /// automatic check may send them again.
    private var credentialsRejected = false
    private var signedInOnThisNetwork = false
    /// The gateway already asked whether it leads to the VIT portal, so that each
    /// network is asked at most once.
    private var gatewayCheckedForCampus: String?
    private var notifiedKeychainApproval = false

    private var runTask: Task<Void, Never>?
    private var runID = 0
    /// True while the current run is only waiting (settling, or backing off between
    /// probes), when a newer request should replace it rather than queue behind it.
    private var runIsInterruptible = false
    private var pending: Request?

    private var healthTask: Task<Void, Never>?
    private var healthID = 0

    private var recoveryTask: Task<Void, Never>?
    private var recoveryID = 0
    /// What asked for the most recent check, so that a check the network never
    /// answered can be finished on the same terms.
    private var lastTrigger: Trigger = .automatic

    init(
        detector: PortalDetector,
        client: ProntoClient,
        credentials: any CredentialStore,
        settings: any EngineSettings,
        notifier: any Notifying,
        sessions: any SessionRecording,
        networkNames: any NetworkNaming = NoNetworkName(),
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() },
        timing: Timing = Timing(),
        healthChecker: HealthChecker = HealthChecker()
    ) {
        self.detector = detector
        self.client = client
        self.credentials = credentials
        self.settings = settings
        self.notifier = notifier
        self.sessions = sessions
        self.networkNames = networkNames
        self.clock = clock
        self.now = now
        self.timing = timing
        self.healthChecker = healthChecker
        self.autoLoginEnabled = settings.autoLoginEnabled
    }

    // MARK: Observing

    /// The current state, followed by every change. Each access is a new subscription.
    var states: AsyncStream<EngineState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: EngineState.self)
        continuation.yield(state)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func set(_ newState: EngineState) {
        guard newState != state else { return }
        state = newState
        Log.engine.debug("state: \(String(describing: newState))")
        for continuation in subscribers.values {
            continuation.yield(newState)
        }
    }

    // MARK: Inputs

    func handle(_ event: NetworkEvent) {
        switch event {
        case .wifiUp(let interface, let gateway):
            let arrived = Network(interface: interface, gateway: gateway)
            let sameNetwork = network?.isSameNetwork(as: arrived) ?? false
            network = arrived
            if sameNetwork {
                // The gateway may only become known after we signed in.
                if signedInOnThisNetwork, let gateway {
                    settings.rememberCampusGateway(gateway)
                }
            } else {
                suppressAutoLoginUntilNextNetworkChange = false
                signedInOnThisNetwork = false
                gatewayCheckedForCampus = nil
                set(.checking)
            }
            requestRun(.automatic, settle: timing.settleDelay)

        case .wifiDown:
            cancelRun()
            stopHealthCheck()
            stopRecoveryWatch()
            network = nil
            suppressAutoLoginUntilNextNetworkChange = false
            signedInOnThisNetwork = false
            gatewayCheckedForCampus = nil
            set(.noWiFi)

        case .didWake:
            guard network != nil else { return }
            requestRun(.automatic)
        }
    }

    /// The user asked to connect: overrides auto-login being off, a manual sign-out,
    /// and previously rejected credentials.
    func connectNow() {
        suppressAutoLoginUntilNextNetworkChange = false
        credentialsRejected = false
        guard network != nil else {
            set(.noWiFi)
            return
        }
        requestRun(.user)
    }

    func setAutoLogin(_ enabled: Bool) {
        autoLoginEnabled = enabled
        settings.setAutoLoginEnabled(enabled)
        if enabled, state == .portalDetected, !suppressAutoLoginUntilNextNetworkChange {
            requestRun(.automatic)
        }
    }

    func credentialsChanged() {
        credentialsRejected = false
        guard network != nil else { return }
        switch state {
        case .needsCredentials, .keychainLocked, .failed(.wrongCredentials):
            requestRun(.automatic)
        default:
            break
        }
    }

    /// Signs out of the portal. Auto-login then stays out of the way until the
    /// network changes or the user asks to connect.
    func logout() {
        guard network != nil else { return }
        stopHealthCheck()
        stopRecoveryWatch()
        cancelRun()
        suppressAutoLoginUntilNextNetworkChange = true
        set(.checking)

        let id = runID
        runTask = Task { await self.signOut(id: id) }
    }

    /// Stops all background work. The engine is not usable afterwards.
    func shutdown() {
        cancelRun()
        stopHealthCheck()
        stopRecoveryWatch()
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    // MARK: Runs

    /// Asks for a check. Only one runs at a time: a request made while one is busy
    /// becomes a single follow-up, and a request made while one is merely waiting
    /// replaces it.
    private func requestRun(_ trigger: Trigger, settle: Duration? = nil) {
        stopHealthCheck()
        if runTask != nil, !runIsInterruptible {
            let merged = max(pending?.trigger ?? trigger, trigger)
            pending = Request(trigger: merged, settle: settle ?? pending?.settle)
            return
        }
        startRun(Request(trigger: max(pending?.trigger ?? trigger, trigger), settle: settle))
    }

    private func startRun(_ request: Request) {
        // The run does its own probing, and restarts the health check if it ends connected.
        stopHealthCheck()
        stopRecoveryWatch()
        runTask?.cancel()
        runID += 1
        // A run that begins by settling can be replaced from the moment it is created.
        runIsInterruptible = request.settle != nil
        pending = nil
        let id = runID
        runTask = Task { await self.run(request, id: id) }
    }

    private func cancelRun() {
        runTask?.cancel()
        runTask = nil
        runID += 1
        runIsInterruptible = false
        pending = nil
    }

    private func run(_ request: Request, id: Int) async {
        if let settle = request.settle {
            guard await interruptibleSleep(settle, id: id) else { return }
        }
        lastTrigger = request.trigger
        await checkAndAct(request.trigger, id: id)
        finishRun(id)
    }

    private func finishRun(_ id: Int) {
        guard id == runID else { return }
        runTask = nil
        runIsInterruptible = false
        if let next = pending {
            startRun(next)
        } else if case .failed = state {
            startRecoveryWatch()
        }
    }

    /// True while `id` is still the run in charge. Checked after every suspension,
    /// because anything may have happened in the meantime.
    private func isCurrent(_ id: Int) -> Bool {
        id == runID && !Task.isCancelled
    }

    /// Sleeps in a way a newer request may cut short. Returns false if this run has
    /// been replaced or cancelled.
    private func interruptibleSleep(_ duration: Duration, id: Int) async -> Bool {
        runIsInterruptible = true
        try? await clock.sleep(for: duration)
        guard isCurrent(id) else { return false }
        runIsInterruptible = false
        return true
    }

    // MARK: Check and act

    private func checkAndAct(_ trigger: Trigger, id: Int) async {
        var connectedSince: Date?
        if case .connected(let since) = state {
            connectedSince = since
        } else {
            set(.checking)
        }

        var result = await detector.probe(overallTimeout: timing.probeTimeout)
        guard isCurrent(id) else { return }

        // A probe error says nothing about the network yet, so try again a few
        // times. These retries carry no credentials.
        for delay in timing.probeRetryDelays {
            guard case .error = result else { break }
            set(.checking)
            if pending != nil { return }
            guard await interruptibleSleep(delay, id: id) else { return }
            result = await detector.probe(overallTimeout: timing.probeTimeout)
            guard isCurrent(id) else { return }
        }
        Log.engine.debug("probe result: \(String(describing: result))")

        switch result {
        case .online:
            if !isKnownCampusNetwork {
                await learnCampusFromGateway()
                guard isCurrent(id) else { return }
            }
            if suppressAutoLoginUntilNextNetworkChange {
                set(.online(campus: isKnownCampusNetwork))
            } else if isKnownCampusNetwork {
                set(.connected(since: connectedSince ?? now()))
                startHealthCheck()
            } else {
                set(.online(campus: false))
            }

        case .vitPortal:
            if let gateway = network?.gateway {
                settings.rememberCampusGateway(gateway)
            }
            if trigger != .user {
                if !autoLoginEnabled || suppressAutoLoginUntilNextNetworkChange {
                    set(.portalDetected)
                    return
                }
                if credentialsRejected {
                    set(.failed(.wrongCredentials))
                    return
                }
            }
            await signIn(trigger, id: id)

        case .otherPortal:
            set(.notCampus)

        case .dnsFailure:
            set(.failed(.dnsFailure))

        case .error(let message):
            set(.failed(.network(message)))
        }
    }

    /// Only ever called from the `.vitPortal` branch above.
    private func signIn(_ trigger: Trigger, id: Int) async {
        // Only a run the user asked for may let macOS show its Keychain dialog.
        let lookup: CredentialLookup
        do {
            lookup = try credentials.load(allowPrompt: trigger == .user)
        } catch {
            Log.storage.error("could not read the saved sign-in: \(String(describing: error))")
            set(.failed(.unknown))
            return
        }
        let saved: Credentials
        switch lookup {
        case .found(let credentials):
            saved = credentials
            notifiedKeychainApproval = false
        case .missing:
            set(.needsCredentials)
            return
        case .needsApproval:
            set(.keychainLocked)
            // Say so once, not on every check that runs into it.
            if !notifiedKeychainApproval {
                notifiedKeychainApproval = true
                await notifier.notify(.keychainApprovalNeeded)
            }
            return
        }

        set(.loggingIn)
        let outcome = await client.login(
            userId: saved.userId,
            password: saved.password,
            gateway: network?.gateway
        )
        guard isCurrent(id) else { return }

        switch outcome {
        case .failure(let reason):
            if reason == .wrongCredentials {
                credentialsRejected = true
            }
            await fail(reason, trigger)

        case .success:
            signedInOnThisNetwork = true
            for attempt in 0..<timing.revalidationAttempts {
                if attempt > 0 {
                    try? await clock.sleep(for: timing.revalidationDelay)
                    guard isCurrent(id) else { return }
                }
                let result = await detector.probe(overallTimeout: timing.probeTimeout)
                guard isCurrent(id) else { return }
                if result == .online {
                    set(.connected(since: now()))
                    startHealthCheck()
                    await notifier.notify(.connected)
                    return
                }
            }
            await fail(.noInternetAfterLogin, trigger)
        }
    }

    private func fail(_ reason: FailureReason, _ trigger: Trigger) async {
        set(.failed(reason))
        await notifier.notify(.loginFailed(reason, afterSessionExpiry: trigger == .sessionExpired))
    }

    private func signOut(id: Int) async {
        let outcome = await client.logout(gateway: network?.gateway, now: now())
        guard isCurrent(id) else { return }
        if let session = outcome.session {
            await sessions.record(session)
            guard isCurrent(id) else { return }
        }
        await notifier.notify(.loggedOut(outcome.session))
        guard isCurrent(id) else { return }

        // The manual sign-out flag is set, so this settles without signing back in.
        lastTrigger = .automatic
        await checkAndAct(.automatic, id: id)
        finishRun(id)
    }

    /// Already online on a network we have not seen the portal on: ask the gateway,
    /// once, whether this is the campus network. No credentials are involved.
    private func learnCampusFromGateway() async {
        guard let gateway = network?.gateway, gatewayCheckedForCampus != gateway else { return }
        gatewayCheckedForCampus = gateway
        if await detector.gatewayLeadsToVITPortal(gateway, overallTimeout: timing.gatewayCheckTimeout) {
            Log.engine.debug("the gateway leads to the VIT portal: campus network")
            settings.rememberCampusGateway(gateway)
        }
    }

    private var isKnownCampusNetwork: Bool {
        if signedInOnThisNetwork { return true }
        if let gateway = network?.gateway, settings.knownCampusGateways.contains(gateway) { return true }
        return networkNames.currentNetworkMatches(settings.campusNetworkNames)
    }

    // MARK: Recovery watch

    /// A failure is not the last word. While failed, keep looking with probes that
    /// carry no credentials.
    ///
    /// If the check failed because the network never answered (a probe error, or a
    /// name that would not resolve), no sign-in was ever attempted, so the first real
    /// answer finishes that check on its original terms. After any other failure a
    /// sign-in was attempted, so the watch only notices the internet working; it
    /// never signs in again by itself.
    private func startRecoveryWatch() {
        stopRecoveryWatch()
        let id = recoveryID
        let detector = detector
        let clock = clock
        let timing = timing
        let checkWasNeverAnswered: Bool
        switch state {
        case .failed(.network), .failed(.dnsFailure): checkWasNeverAnswered = true
        default: checkWasNeverAnswered = false
        }
        recoveryTask = Task {
            var delay = timing.firstRecoveryCheck
            while true {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                delay = timing.recoveryCheckInterval
                let result = await detector.probe(overallTimeout: timing.probeTimeout)
                if Task.isCancelled { return }
                switch result {
                case .online where !checkWasNeverAnswered:
                    await self.recoveredWhileFailed(id: id)
                    return
                case .online, .vitPortal, .otherPortal:
                    if checkWasNeverAnswered {
                        self.finishUnansweredCheck(id: id)
                        return
                    }
                case .dnsFailure, .error:
                    break
                }
            }
        }
    }

    private func finishUnansweredCheck(id: Int) {
        guard id == recoveryID, runTask == nil, network != nil, case .failed = state else { return }
        recoveryTask = nil
        Log.engine.debug("the network answers now: finishing the check")
        requestRun(lastTrigger)
    }

    private func stopRecoveryWatch() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryID += 1
    }

    private func recoveredWhileFailed(id: Int) async {
        guard id == recoveryID, runTask == nil, network != nil, case .failed(let reason) = state else { return }
        recoveryTask = nil
        Log.engine.debug("the internet works after all")
        if isKnownCampusNetwork, !suppressAutoLoginUntilNextNetworkChange {
            set(.connected(since: now()))
            startHealthCheck()
            if reason == .noInternetAfterLogin {
                // The sign-in did work; its confirmation just came late.
                await notifier.notify(.connected)
            }
        } else {
            set(.online(campus: isKnownCampusNetwork))
        }
    }

    // MARK: Health check

    private func startHealthCheck() {
        stopHealthCheck()
        let id = healthID
        let checker = healthChecker
        let detector = detector
        let clock = clock
        let now = now
        healthTask = Task {
            let verdict = await checker.run(clock: clock, now: now) {
                await detector.probe(overallTimeout: checker.probeTimeout)
            }
            self.healthCheckEnded(verdict, id: id)
        }
    }

    private func stopHealthCheck() {
        healthTask?.cancel()
        healthTask = nil
        healthID += 1
    }

    private func healthCheckEnded(_ verdict: HealthChecker.Verdict?, id: Int) {
        guard id == healthID, let verdict, network != nil else { return }
        healthTask = nil
        switch verdict {
        case .sessionLost:
            // The session has probably expired. This is the only automatic path
            // back to a sign-in while the network stays the same.
            Log.engine.debug("health check: session lost")
            set(.checking)
            requestRun(.sessionExpired)
        case .wokeFromSleep:
            Log.engine.debug("health check: woke from sleep")
            requestRun(.automatic)
        }
    }
}
