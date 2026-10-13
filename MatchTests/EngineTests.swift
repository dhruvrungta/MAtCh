import Foundation
import os
import Testing
@testable import Match

/// A real engine wired to a pretend network and a clock the test controls.
private final class Harness: Sendable {
    static let settle: Duration = .milliseconds(1500)
    static let healthInterval: Duration = .seconds(60)

    let portal = FakePortal()
    let time = TestTime()
    let credentials: InMemoryCredentialStore
    let settings: InMemorySettings
    let notifier = RecordingNotifier()
    let sessions = RecordingSessions()
    let engine: MatchEngine
    private let seen = OSAllocatedUnfairLock(initialState: [EngineState]())

    var clock: TestClock { time.clock }

    init(
        credentials: Credentials? = Credentials(userId: "25BIT0088", password: "s3cret pass"),
        autoLogin: Bool = true,
        knownGateways: Set<String> = []
    ) async {
        self.credentials = InMemoryCredentialStore(credentials)
        self.settings = InMemorySettings(autoLogin: autoLogin, gateways: knownGateways)
        let time = time
        engine = MatchEngine(
            detector: PortalDetector(http: portal, endpoints: .test),
            client: ProntoClient(http: portal, endpoints: .test),
            credentials: self.credentials,
            settings: settings,
            notifier: notifier,
            sessions: sessions,
            clock: time.clock,
            now: { time.date }
        )
        let states = await engine.states
        Task { [seen] in
            for await state in states {
                seen.withLock { $0.append(state) }
            }
        }
    }

    /// Every state the engine has passed through, in order.
    var history: [EngineState] { seen.withLock { $0 } }

    /// Brings Wi-Fi up and lets the settle delay pass.
    func wifiUp(gateway: String? = "10.0.0.1") async {
        await engine.handle(.wifiUp(interface: "en0", gateway: gateway))
        #expect(await clock.waitForSleep(of: Self.settle))
        clock.advance(by: Self.settle)
    }

    func reaches(_ expected: EngineState) async -> Bool {
        await eventually { await self.engine.state == expected }
    }

    func reachesConnected() async -> Bool {
        await eventually { await self.engine.state.isConnected }
    }

    /// Lets one health-check interval pass, and waits for that check to finish.
    func healthTick() async {
        #expect(await clock.waitForSleep(of: Self.healthInterval))
        let probes = portal.probeCount
        clock.advance(by: Self.healthInterval)
        #expect(await eventually { self.portal.probeCount > probes })
    }

    /// Signs in on a fresh network and waits for the health check to start.
    func connect() async {
        await wifiUp()
        #expect(await reachesConnected())
        #expect(await clock.waitForSleep(of: Self.healthInterval))
    }

    /// Arrives on a campus network that is already online, and waits for the health check.
    func connectWithoutSigningIn() async {
        await wifiUp()
        #expect(await reachesConnected())
        #expect(await clock.waitForSleep(of: Self.healthInterval))
        #expect(portal.postCount == 0)
    }

    func shutdown() async {
        await engine.shutdown()
    }
}

@Suite struct MatchEngineTests {
    // MARK: Signing in

    @Test func happyPath() async throws {
        let harness = await Harness()
        #expect(await harness.engine.state == .noWiFi)

        await harness.wifiUp()
        #expect(await harness.reachesConnected())

        #expect(await eventually { harness.history.count == 4 })
        #expect(harness.history == [.noWiFi, .checking, .loggingIn, .connected(since: harness.time.date)])

        // Probe, sign in, then one probe to confirm the internet is up.
        #expect(harness.portal.probeCount == 2)
        #expect(harness.portal.postCount == 1)
        let login = try #require(harness.portal.loginRequests.first)
        #expect(login.url.absoluteString == "http://portal.test/cgi-bin/authlogin?URI=http://example.com")
        #expect(login.body == Data("userId=25BIT0088&password=s3cret+pass&serviceName=ProntoAuthentication".utf8))

        #expect(await eventually { harness.notifier.events == [.connected] })
        #expect(harness.settings.knownCampusGateways == ["10.0.0.1"])
        await harness.shutdown()
    }

    @Test func wrongCredentialsAreNeverResentAutomatically() async {
        let harness = await Harness()
        harness.portal.setLogin(.reject("<html>Invalid userid or password</html>"))

        await harness.wifiUp()
        #expect(await harness.reaches(.failed(.wrongCredentials)))
        #expect(harness.portal.postCount == 1)
        #expect(await eventually {
            harness.notifier.events == [.loginFailed(.wrongCredentials, afterSessionExpiry: false)]
        })

        // A wake checks again but must not send the rejected credentials.
        let probesBeforeWake = harness.portal.probeCount
        await harness.engine.handle(.didWake)
        #expect(await eventually { harness.portal.probeCount == probesBeforeWake + 1 })
        #expect(await harness.reaches(.failed(.wrongCredentials)))
        #expect(harness.portal.postCount == 1)

        // Nor may a change of network.
        let probesBeforeChange = harness.portal.probeCount
        await harness.engine.handle(.wifiDown)
        await harness.wifiUp(gateway: "10.0.9.1")
        #expect(await eventually { harness.portal.probeCount == probesBeforeChange + 1 })
        #expect(await harness.reaches(.failed(.wrongCredentials)))
        #expect(harness.portal.postCount == 1)

        // The user asking is what it takes.
        harness.portal.setLogin(.accept)
        await harness.engine.connectNow()
        #expect(await harness.reachesConnected())
        #expect(harness.portal.postCount == 2)
        await harness.shutdown()
    }

    @Test func changedCredentialsAreTriedAgain() async {
        let harness = await Harness()
        harness.portal.setLogin(.reject("wrong password"))
        await harness.wifiUp()
        #expect(await harness.reaches(.failed(.wrongCredentials)))

        harness.portal.setLogin(.accept)
        try? harness.credentials.save(Credentials(userId: "25BIT0088", password: "better"))
        await harness.engine.credentialsChanged()
        #expect(await harness.reachesConnected())
        #expect(harness.portal.postCount == 2)
        await harness.shutdown()
    }

    @Test func otherPortalsNeverSeeCredentials() async {
        let harness = await Harness()
        harness.portal.setMode(.foreignPortal)

        await harness.wifiUp()
        #expect(await harness.reaches(.notCampus))

        await harness.engine.connectNow()
        #expect(await eventually { harness.portal.probeCount == 2 })
        #expect(await harness.reaches(.notCampus))

        #expect(harness.portal.postCount == 0)
        #expect(harness.portal.requests.allSatisfy { $0.method == .get && $0.url.path == "/generate_204" })
        #expect(harness.notifier.events.isEmpty)
        await harness.shutdown()
    }

    @Test func missingCredentialsAskForThem() async {
        let harness = await Harness(credentials: nil)
        await harness.wifiUp()
        #expect(await harness.reaches(.needsCredentials))
        #expect(harness.portal.postCount == 0)

        try? harness.credentials.save(Credentials(userId: "25BIT0088", password: "pw"))
        await harness.engine.credentialsChanged()
        #expect(await harness.reachesConnected())
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    @Test func noInternetAfterLoginFailsAfterThreeRevalidations() async {
        let harness = await Harness()
        harness.portal.setLogin(.acceptButStayCaptive)

        await harness.wifiUp()
        for _ in 0..<2 {
            #expect(await harness.clock.waitForSleep(of: .seconds(2)))
            #expect(await harness.engine.state == .loggingIn)
            harness.clock.advance(by: .seconds(2))
        }
        #expect(await harness.reaches(.failed(.noInternetAfterLogin)))

        // One probe before signing in, three after.
        #expect(harness.portal.probeCount == 4)
        #expect(harness.portal.postCount == 1)
        #expect(await eventually {
            harness.notifier.events == [.loginFailed(.noInternetAfterLogin, afterSessionExpiry: false)]
        })
        await harness.shutdown()
    }

    @Test func accountProblemsAreReported() async {
        let harness = await Harness()
        harness.portal.setLogin(.reject("Your max session limit is reached"))
        await harness.wifiUp()
        #expect(await harness.reaches(.failed(.sessionLimit)))
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    // MARK: Auto-login off

    @Test func autoLoginOffStopsAtThePortal() async {
        let harness = await Harness(autoLogin: false)
        await harness.wifiUp()
        #expect(await harness.reaches(.portalDetected))
        #expect(harness.portal.postCount == 0)

        await harness.engine.connectNow()
        #expect(await harness.reachesConnected())
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    @Test func turningAutoLoginOnSignsIn() async {
        let harness = await Harness(autoLogin: false)
        await harness.wifiUp()
        #expect(await harness.reaches(.portalDetected))

        await harness.engine.setAutoLogin(true)
        #expect(await harness.reachesConnected())
        #expect(harness.settings.autoLoginEnabled)
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    // MARK: Known campus networks

    @Test func onlineOnAKnownCampusGatewayCountsAsConnected() async {
        let harness = await Harness(knownGateways: ["10.0.0.1"])
        harness.portal.setMode(.online)
        await harness.wifiUp(gateway: "10.0.0.1")
        #expect(await harness.reachesConnected())
        #expect(await harness.clock.waitForSleep(of: Harness.healthInterval))
        #expect(harness.portal.postCount == 0)
        // Finding the internet already working is not worth a notification.
        #expect(harness.notifier.events.isEmpty)
        await harness.shutdown()
    }

    @Test func onlineOnAnUnknownGatewayIsJustOnline() async {
        let harness = await Harness(knownGateways: ["10.0.0.1"])
        harness.portal.setMode(.online)
        await harness.wifiUp(gateway: "192.168.1.1")
        #expect(await harness.reaches(.online(campus: false)))
        #expect(harness.portal.postCount == 0)
        // No health check runs off campus.
        #expect(harness.clock.pendingSleeps.isEmpty)
        await harness.shutdown()
    }

    @Test func aKnownGatewayNeverUnlocksCredentials() async {
        let harness = await Harness(knownGateways: ["10.0.0.1"])
        harness.portal.setMode(.foreignPortal)
        await harness.wifiUp(gateway: "10.0.0.1")
        #expect(await harness.reaches(.notCampus))

        harness.portal.setMode(.unreachable)
        await harness.engine.connectNow()
        for delay in [2, 4, 8] {
            #expect(await harness.clock.waitForSleep(of: .seconds(delay)))
            harness.clock.advance(by: .seconds(delay))
        }
        #expect(await harness.reaches(.failed(.network("unreachable"))))
        #expect(harness.portal.postCount == 0)
        await harness.shutdown()
    }

    @Test func aGatewayLearnedAfterSigningInIsRemembered() async {
        let harness = await Harness()
        await harness.wifiUp(gateway: nil)
        #expect(await harness.reachesConnected())
        #expect(harness.settings.knownCampusGateways.isEmpty)

        await harness.wifiUp(gateway: "10.0.0.1")
        #expect(await eventually { harness.portal.probeCount == 3 })
        #expect(await harness.reachesConnected())
        #expect(harness.settings.knownCampusGateways == ["10.0.0.1"])
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    // MARK: Probe errors

    @Test func probeErrorsAreRetriedWithBackoffThenFail() async {
        let harness = await Harness()
        harness.portal.setMode(.unreachable)

        await harness.wifiUp()
        for (index, delay) in [2, 4, 8].enumerated() {
            #expect(await harness.clock.waitForSleep(of: .seconds(delay)))
            #expect(harness.portal.probeCount == index + 1)
            #expect(await harness.engine.state == .checking)
            harness.clock.advance(by: .seconds(delay))
        }
        #expect(await harness.reaches(.failed(.network("unreachable"))))
        #expect(harness.portal.probeCount == 4)
        #expect(harness.portal.postCount == 0)
        // It does not keep trying on its own.
        #expect(harness.clock.pendingSleeps.isEmpty)
        await harness.shutdown()
    }

    @Test func recoveryDuringProbeRetriesCarriesOn() async {
        let harness = await Harness()
        harness.portal.setMode(.unreachable)

        await harness.wifiUp()
        #expect(await harness.clock.waitForSleep(of: .seconds(2)))
        harness.portal.setMode(.captive)
        harness.clock.advance(by: .seconds(2))

        #expect(await harness.reachesConnected())
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    @Test func dnsFailureIsReportedWithoutLooping() async {
        let harness = await Harness()
        harness.portal.setMode(.dnsFailure)
        await harness.wifiUp()
        #expect(await harness.reaches(.failed(.dnsFailure)))
        #expect(harness.portal.probeCount == 1)
        #expect(harness.clock.pendingSleeps.isEmpty)
        await harness.shutdown()
    }

    // MARK: Health check

    @Test func twoFailedHealthChecksDoNotSignInAgainButThreeDo() async {
        let harness = await Harness()
        await harness.connect()
        let before = await harness.engine.state

        // The session expires: the portal is back in the way.
        harness.portal.setMode(.captive)
        await harness.healthTick()
        await harness.healthTick()
        #expect(await harness.clock.waitForSleep(of: Harness.healthInterval))
        #expect(await harness.engine.state == before)
        #expect(harness.portal.postCount == 1)

        harness.clock.advance(by: Harness.healthInterval)
        #expect(await eventually { harness.portal.postCount == 2 })
        #expect(await harness.reachesConnected())
        #expect(await eventually { harness.history.count { $0 == .loggingIn } == 2 })
        #expect(await eventually { harness.notifier.events == [.connected, .connected] })
        await harness.shutdown()
    }

    @Test func aGoodHealthCheckResetsTheCount() async {
        let harness = await Harness()
        await harness.connect()

        harness.portal.setMode(.unreachable)
        await harness.healthTick()
        await harness.healthTick()
        harness.portal.setMode(.online)
        await harness.healthTick()
        harness.portal.setMode(.unreachable)
        await harness.healthTick()
        await harness.healthTick()

        #expect(await harness.clock.waitForSleep(of: Harness.healthInterval))
        #expect(await harness.engine.state.isConnected)
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    @Test func failedReloginAfterExpiryIsReportedAsSuch() async {
        let harness = await Harness()
        await harness.connect()

        harness.portal.setMode(.captive)
        harness.portal.setLogin(.reject("account expired"))
        await harness.healthTick()
        await harness.healthTick()
        #expect(await harness.clock.waitForSleep(of: Harness.healthInterval))
        harness.clock.advance(by: Harness.healthInterval)

        #expect(await harness.reaches(.failed(.accountExpired)))
        #expect(await eventually {
            harness.notifier.events == [.connected, .loginFailed(.accountExpired, afterSessionExpiry: true)]
        })
        await harness.shutdown()
    }

    @Test func wakeProbesImmediately() async {
        let harness = await Harness()
        await harness.connect()
        let before = await harness.engine.state
        let probes = harness.portal.probeCount

        await harness.engine.handle(.didWake)
        #expect(await eventually { harness.portal.probeCount == probes + 1 })
        // Still connected, since the same moment, with the health check running again.
        #expect(await harness.clock.waitForSleep(of: Harness.healthInterval))
        #expect(await harness.engine.state == before)
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    @Test func wakeToAnExpiredSessionSignsInAgain() async {
        let harness = await Harness()
        await harness.connect()

        harness.portal.setMode(.captive)
        await harness.engine.handle(.didWake)
        #expect(await eventually { harness.portal.postCount == 2 })
        #expect(await harness.reachesConnected())
        await harness.shutdown()
    }

    @Test func aLongGapBetweenTicksIsTreatedAsWakingUp() async {
        let harness = await Harness()
        await harness.connect()
        let probes = harness.portal.probeCount

        // The session expired while the Mac slept; no need to wait for three failures.
        harness.portal.setMode(.captive)
        harness.time.sleepMac(for: 3600)
        harness.clock.advance(by: Harness.healthInterval)

        #expect(await eventually { harness.portal.postCount == 2 })
        #expect(await harness.reachesConnected())
        #expect(harness.portal.probeCount == probes + 2)
        await harness.shutdown()
    }

    @Test func wifiDownStopsEverything() async {
        let harness = await Harness()
        await harness.connect()

        await harness.engine.handle(.wifiDown)
        #expect(await harness.engine.state == .noWiFi)
        #expect(await eventually { harness.clock.pendingSleeps.isEmpty })

        let probes = harness.portal.probeCount
        await harness.engine.handle(.didWake)
        await harness.engine.connectNow()
        #expect(await harness.engine.state == .noWiFi)
        #expect(harness.portal.probeCount == probes)
        await harness.shutdown()
    }

    // MARK: Signing out

    @Test func manualLogoutSuppressesAutoLoginUntilTheNetworkChanges() async {
        let harness = await Harness()
        await harness.connect()

        await harness.engine.logout()
        #expect(await harness.reaches(.portalDetected))
        #expect(harness.portal.logoutCount == 1)
        #expect(harness.portal.postCount == 1)
        #expect(harness.sessions.sessions.map(\.duration) == [3723])
        #expect(harness.sessions.sessions.first?.uploadBytes == 1234)
        #expect(harness.sessions.sessions.first?.downloadBytes == 5678)
        #expect(await eventually { harness.notifier.events.count == 2 })
        #expect(harness.notifier.events.last == .loggedOut(harness.sessions.sessions.first))
        // Nothing is left ticking.
        #expect(harness.clock.pendingSleeps.isEmpty)

        // A wake looks, but does not sign back in.
        let probes = harness.portal.probeCount
        await harness.engine.handle(.didWake)
        #expect(await eventually { harness.portal.probeCount == probes + 1 })
        #expect(await harness.reaches(.portalDetected))
        #expect(harness.portal.postCount == 1)

        // Neither does the same network reporting in again.
        await harness.wifiUp()
        #expect(await eventually { harness.portal.probeCount == probes + 2 })
        #expect(await harness.reaches(.portalDetected))
        #expect(harness.portal.postCount == 1)

        // A different network lifts the hold.
        await harness.engine.handle(.wifiDown)
        await harness.wifiUp()
        #expect(await harness.reachesConnected())
        #expect(harness.portal.postCount == 2)
        await harness.shutdown()
    }

    @Test func connectAfterManualLogoutSignsIn() async {
        let harness = await Harness()
        await harness.connect()
        await harness.engine.logout()
        #expect(await harness.reaches(.portalDetected))

        await harness.engine.connectNow()
        #expect(await harness.reachesConnected())
        #expect(harness.portal.postCount == 2)
        await harness.shutdown()
    }

    // MARK: Concurrency

    @Test func overlappingTriggersCoalesceIntoOneFollowUp() async {
        let harness = await Harness()
        await harness.portal.loginGate.close()

        await harness.wifiUp()
        #expect(await eventually { await harness.portal.loginGate.waiting == 1 })
        #expect(await harness.engine.state == .loggingIn)

        // Everything that arrives while the sign-in is in flight...
        for _ in 0..<5 {
            await harness.engine.handle(.didWake)
        }
        await harness.engine.connectNow()
        await harness.engine.handle(.didWake)
        #expect(await harness.portal.loginGate.waiting == 1)
        #expect(harness.portal.probeCount == 1)

        // ...becomes exactly one more check once it finishes.
        await harness.portal.loginGate.open()
        #expect(await eventually { harness.portal.probeCount == 3 })
        #expect(await harness.reachesConnected())
        #expect(await harness.clock.waitForSleep(of: Harness.healthInterval))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.portal.probeCount == 3)
        #expect(harness.portal.postCount == 1)
        await harness.shutdown()
    }

    @Test func aBurstOfNetworkEventsActsOnlyOnTheLast() async {
        let harness = await Harness(knownGateways: ["10.0.0.1"])
        harness.portal.setMode(.online)

        await harness.engine.handle(.wifiUp(interface: "en0", gateway: nil))
        await harness.engine.handle(.wifiUp(interface: "en0", gateway: "10.0.0.1"))
        await harness.engine.handle(.wifiUp(interface: "en0", gateway: "10.0.0.1"))
        #expect(await eventually { harness.clock.pendingSleeps == [Harness.settle] })
        #expect(harness.portal.probeCount == 0)

        harness.clock.advance(by: Harness.settle)
        #expect(await harness.reachesConnected())
        #expect(harness.portal.probeCount == 1)
        await harness.shutdown()
    }
}

@Suite struct CampusRecognitionTests {
    @Test func alreadyOnlineOnCampusIsRecognisedThroughTheGateway() async throws {
        let harness = await Harness()
        harness.portal.setMode(.online)
        harness.portal.setCampusGateways(["10.0.0.1"])

        await harness.wifiUp(gateway: "10.0.0.1")
        #expect(await harness.reachesConnected())
        #expect(await harness.clock.waitForSleep(of: Harness.healthInterval))

        // Recognised by asking the gateway for its front page: no credentials, no notification.
        let check = try #require(harness.portal.gatewayRequests.first)
        #expect(harness.portal.gatewayRequests.count == 1)
        #expect(check.method == .get)
        #expect(check.url.absoluteString == "http://10.0.0.1")
        #expect(check.body == nil)
        #expect(harness.portal.postCount == 0)
        #expect(harness.settings.knownCampusGateways == ["10.0.0.1"])
        #expect(harness.notifier.events.isEmpty)
        await harness.shutdown()
    }

    @Test func anOrdinaryGatewayIsAskedOnlyOncePerNetwork() async {
        let harness = await Harness()
        harness.portal.setMode(.online)

        await harness.wifiUp(gateway: "192.168.1.1")
        #expect(await harness.reaches(.online(campus: false)))
        #expect(harness.portal.gatewayRequests.count == 1)

        for expected in 2...3 {
            await harness.engine.handle(.didWake)
            #expect(await eventually { harness.portal.probeCount == expected })
            #expect(await harness.reaches(.online(campus: false)))
        }
        #expect(harness.portal.gatewayRequests.count == 1)

        // A different network is asked afresh.
        await harness.engine.handle(.wifiDown)
        await harness.wifiUp(gateway: "192.168.7.1")
        #expect(await harness.reaches(.online(campus: false)))
        #expect(harness.portal.gatewayRequests.count == 2)
        #expect(harness.settings.knownCampusGateways.isEmpty)
        #expect(harness.portal.postCount == 0)
        await harness.shutdown()
    }

    @Test func aCampusGatewayAloneNeverSendsCredentials() async {
        let harness = await Harness()
        harness.portal.setMode(.online)
        harness.portal.setCampusGateways(["10.0.0.1"])
        await harness.connectWithoutSigningIn()

        // Later a different portal appears on the same network: still nothing is sent.
        harness.portal.setMode(.foreignPortal)
        await harness.engine.connectNow()
        #expect(await harness.reaches(.notCampus))
        #expect(harness.portal.postCount == 0)
        await harness.shutdown()
    }

    @Test func noGatewayMeansNoCheck() async {
        let harness = await Harness()
        harness.portal.setMode(.online)
        await harness.wifiUp(gateway: nil)
        #expect(await harness.reaches(.online(campus: false)))
        #expect(harness.portal.gatewayRequests.isEmpty)
        await harness.shutdown()
    }
}

@Suite struct GatewayCheckTests {
    private func leadsToPortal(_ result: Result<HTTPResponse, HTTPError>) async -> (Bool, ScriptedHTTPClient) {
        let http = ScriptedHTTPClient([result])
        let detector = PortalDetector(http: http, endpoints: .production)
        return (await detector.gatewayLeadsToVITPortal("172.17.104.1", overallTimeout: .seconds(2)), http)
    }

    @Test func aRedirectToThePortalMeansCampus() async throws {
        let location = "http://phc.prontonetworks.com/redirect.html?URI=http://172.17.104.1/"
        let (campus, http) = await leadsToPortal(.success(.redirect(to: location)))
        #expect(campus)
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "http://172.17.104.1")
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
    }

    @Test func anythingElseDoesNot() async {
        #expect(await leadsToPortal(.success(.html(200, "<html>Router settings</html>"))).0 == false)
        #expect(await leadsToPortal(.success(.redirect(to: "http://192.168.1.1/login.html"))).0 == false)
        #expect(await leadsToPortal(.success(HTTPResponse(status: 204))).0 == false)
        #expect(await leadsToPortal(.failure(.other("connection refused"))).0 == false)
        #expect(await leadsToPortal(.failure(.timedOut)).0 == false)
    }
}
