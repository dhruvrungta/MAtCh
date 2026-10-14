import AppKit
import Foundation
import Observation

/// What the UI shows. Mirrors the engine's state and the settings on the main actor,
/// and carries the user's actions back.
@MainActor
@Observable
final class AppState {
    enum PrimaryAction: Equatable {
        case connect
        case logOut
        case addCredentials
        case tryAgain
        case unlock

        var title: String {
            switch self {
            case .connect: "Connect"
            case .logOut: "Log out"
            case .addCredentials: "Add credentials"
            case .tryAgain: "Try again"
            case .unlock: "Unlock"
            }
        }
    }

    enum SettingsTab: Hashable {
        case general, account, network, history, advanced, about
    }

    /// Follows the engine. Only the engine's stream (and tests) should set it.
    var engineState: EngineState = .noWiFi
    private(set) var savedUserId: String?
    /// True when macOS will ask the user before this build may read the saved sign-in.
    private(set) var keychainApprovalNeeded = false
    private(set) var autoLoginEnabled: Bool
    private(set) var launchAtLogin = false
    private(set) var notifications: [NotificationCategory: Bool] = [:]
    private(set) var showNetworkName: Bool
    private(set) var networkName: String?
    private(set) var campusNetworkNames: [String]
    private(set) var rememberedGatewayCount = 0
    private(set) var updateChecksEnabled: Bool
    /// A newer version that has been published, if a check found one.
    private(set) var availableUpdate: ReleaseInfo?
    /// What the last check the user asked for found, in words.
    private(set) var updateCheckMessage: String?
    private(set) var isCheckingForUpdates = false
    var selectedSettingsTab: SettingsTab = .general

    let sessions: SessionStore
    let usage: UsageMonitor
    let location = LocationPermission()
    /// True when a debug build has been pointed at the mock portal.
    let usingMockPortal: Bool
    let launchAtLoginAvailable = LoginItem.isAvailable

    /// Set by the app's wiring: shows the onboarding window.
    @ObservationIgnored var showOnboarding: () -> Void = {}

    @ObservationIgnored private let engine: MatchEngine
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let networkNames: any NetworkNaming
    @ObservationIgnored private let updateChecker: UpdateChecker?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var updateSchedule: Task<Void, Never>?

    init(
        engine: MatchEngine,
        credentials: any CredentialStore,
        settings: SettingsStore,
        sessions: SessionStore,
        usage: UsageMonitor,
        networkNames: any NetworkNaming,
        updateChecker: UpdateChecker? = nil,
        usingMockPortal: Bool
    ) {
        self.engine = engine
        self.credentials = credentials
        self.settings = settings
        self.sessions = sessions
        self.usage = usage
        self.networkNames = networkNames
        self.updateChecker = updateChecker
        self.updateChecksEnabled = settings.updateChecksEnabled
        self.usingMockPortal = usingMockPortal
        self.autoLoginEnabled = settings.autoLoginEnabled
        self.showNetworkName = settings.showNetworkName
        self.campusNetworkNames = settings.campusNetworkNames
        reloadSettings()
    }

    func start() {
        refreshKeychainStatus()
        observation = Task { [weak self, engine] in
            for await state in await engine.states {
                self?.engineState = state
                self?.usage.connectionChanged(to: state)
                self?.refreshNetworkDetails()
                // The engine may have had the item approved (Connect) or found it locked.
                self?.refreshKeychainStatus()
            }
        }
    }

    private func reloadSettings() {
        autoLoginEnabled = settings.autoLoginEnabled
        updateChecksEnabled = settings.updateChecksEnabled
        showNetworkName = settings.showNetworkName
        campusNetworkNames = settings.campusNetworkNames
        rememberedGatewayCount = settings.knownCampusGateways.count
        launchAtLogin = LoginItem.isEnabled
        for category in NotificationCategory.allCases {
            notifications[category] = settings.isNotificationEnabled(category)
        }
    }

    // MARK: Updates

    var canCheckForUpdates: Bool { updateChecker != nil }

    /// The line to paste into Terminal to update.
    var updateCommand: String? { updateChecker?.source.installCommand }

    var releasePage: URL? {
        guard let availableUpdate else { return nil }
        return updateChecker?.source.releasePage(for: availableUpdate)
    }

    func setUpdateChecksEnabled(_ enabled: Bool) {
        settings.setUpdateChecksEnabled(enabled)
        updateChecksEnabled = enabled
    }

    /// Looks for a newer version once a day while automatic checks are switched on.
    func startUpdateSchedule() {
        updateSchedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdatesIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func checkForUpdatesIfDue(now: Date = Date()) async {
        guard updateChecksEnabled, UpdateChecker.isDue(lastCheck: settings.lastUpdateCheck, now: now) else { return }
        await checkForUpdates(askedByUser: false, now: now)
    }

    func checkForUpdates(askedByUser: Bool, now: Date = Date()) async {
        guard let updateChecker, !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let outcome = await updateChecker.check()
        settings.setLastUpdateCheck(now)
        switch outcome {
        case .available(let release):
            availableUpdate = release
            updateCheckMessage = nil
        case .upToDate:
            availableUpdate = nil
            updateCheckMessage = askedByUser ? "MAtCh is up to date." : nil
        case .failed(let reason):
            Log.ui.debug("update check failed: \(reason)")
            updateCheckMessage = askedByUser ? "Couldn't check for updates. Try again later." : nil
        }
    }

    func copyUpdateCommand() {
        guard let updateCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(updateCommand, forType: .string)
    }

    func openReleasePage() {
        guard let releasePage else { return }
        NSWorkspace.shared.open(releasePage)
    }

    // MARK: Connection

    func perform(_ action: PrimaryAction) {
        switch action {
        case .connect, .tryAgain:
            Task { await engine.connectNow() }
        case .logOut:
            Task { await engine.logout() }
        case .unlock:
            unlockSavedSignIn()
        case .addCredentials:
            break
        }
    }

    func setAutoLogin(_ enabled: Bool) {
        autoLoginEnabled = enabled
        Task { await engine.setAutoLogin(enabled) }
    }

    // MARK: Credentials

    /// Reads what can be known about the saved sign-in without macOS asking anything.
    func refreshKeychainStatus() {
        do {
            savedUserId = try credentials.savedUserId()
            keychainApprovalNeeded = try credentials.approvalNeeded()
        } catch {
            Log.storage.error("could not read the saved sign-in: \(String(describing: error))")
        }
    }

    /// Validates and saves a sign-in. Returns a message for the user if it could not.
    func saveCredentials(userId: String, password: String) -> String? {
        let normalized = RegistrationNumber.normalize(userId)
        guard RegistrationNumber.isValid(normalized) else {
            return "Enter your registration number in the form \(RegistrationNumber.example)."
        }
        guard !password.isEmpty else {
            return "Enter your Wi-Fi password."
        }
        do {
            try credentials.save(Credentials(userId: normalized, password: password))
        } catch {
            Log.storage.error("could not save the sign-in: \(String(describing: error))")
            return "Couldn't save to the Keychain: \(Self.describe(error))"
        }
        refreshKeychainStatus()
        Task { await engine.credentialsChanged() }
        return nil
    }

    /// Returns a message for the user if the saved sign-in could not be removed.
    func removeCredentials() -> String? {
        do {
            try credentials.clear()
        } catch {
            Log.storage.error("could not remove the sign-in: \(String(describing: error))")
            return "Couldn't remove the saved sign-in: \(Self.describe(error))"
        }
        refreshKeychainStatus()
        return nil
    }

    /// Lets macOS ask the user to approve this build. Only ever called from a click.
    func unlockSavedSignIn() {
        let credentials = credentials
        Task {
            await Task.detached {
                do {
                    // Read twice: if the user picked Allow rather than Always Allow,
                    // the second read asks again now, while they are looking, rather
                    // than at some later sign-in.
                    if case .found = try credentials.load(allowPrompt: true) {
                        _ = try credentials.load(allowPrompt: true)
                    }
                } catch {
                    Log.storage.error("could not unlock the saved sign-in: \(String(describing: error))")
                }
            }.value
            refreshKeychainStatus()
            await engine.credentialsChanged()
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? KeychainError)?.message ?? error.localizedDescription
    }

    // MARK: Settings

    /// Returns a message for the user if the change could not be made.
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        defer { launchAtLogin = LoginItem.isEnabled }
        do {
            try LoginItem.setEnabled(enabled)
            return nil
        } catch {
            Log.ui.error("could not change launch at login: \(error.localizedDescription)")
            return "Couldn't change launch at login: \(error.localizedDescription)"
        }
    }

    func setNotification(_ category: NotificationCategory, enabled: Bool) {
        setAllNotifications([category], enabled: enabled)
    }

    /// Switches several kinds of notification at once, asking macOS for permission
    /// the first time any is switched on.
    func setAllNotifications(_ categories: [NotificationCategory] = NotificationCategory.allCases, enabled: Bool) {
        for category in categories {
            settings.setNotification(category, enabled: enabled)
            notifications[category] = enabled
        }
        if enabled {
            Task { _ = await UserNotifier.requestAuthorization() }
        }
    }

    func setShowNetworkName(_ show: Bool) {
        settings.setShowNetworkName(show)
        showNetworkName = show
        if show, location.status == .notDetermined {
            location.request()
        }
        refreshNetworkDetails()
    }

    func refreshNetworkDetails() {
        networkName = showNetworkName ? networkNames.currentNetworkName() : nil
        rememberedGatewayCount = settings.knownCampusGateways.count
    }

    func setCampusNetworkNames(_ names: [String]) {
        settings.setCampusNetworkNames(names)
        campusNetworkNames = settings.campusNetworkNames
    }

    func forgetCampusGateways() {
        settings.forgetCampusGateways()
        rememberedGatewayCount = 0
    }

    func copyDiagnostics() async {
        let state = engineState
        let secrets = [savedUserId].compactMap { $0 }
        let report = await Task.detached { Diagnostics.report(state: state, secrets: secrets) }.value
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    /// Removes the saved sign-in and every setting, then starts over with onboarding.
    /// Returns a message for the user if it could not.
    func resetEverything() -> String? {
        if let message = removeCredentials() {
            return message
        }
        if launchAtLogin {
            _ = setLaunchAtLogin(false)
        }
        settings.resetAll()
        sessions.clear()
        reloadSettings()
        let autoLogin = autoLoginEnabled
        Task { await engine.setAutoLogin(autoLogin) }
        showOnboarding()
        return nil
    }

    // MARK: Presentation

    var primaryAction: PrimaryAction? {
        switch engineState {
        case .connected: .logOut
        case .portalDetected: .connect
        case .online(campus: true): .connect
        case .needsCredentials: .addCredentials
        case .keychainLocked: .unlock
        case .failed: .tryAgain
        case .noWiFi, .checking, .loggingIn, .online(campus: false), .notCampus: nil
        }
    }

    /// Shown when approval is needed but nothing is forcing the issue yet.
    var showsUnlockReminder: Bool {
        keychainApprovalNeeded && engineState != .keychainLocked
    }

    var iconAppearance: StatusIcon.Appearance {
        StatusIcon.Appearance(state: engineState)
    }
}
