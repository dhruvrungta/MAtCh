import Foundation
import Testing
@testable import Match

private let allFailureReasons: [FailureReason] = [
    .wrongCredentials, .accountExpired, .sessionLimit, .dnsFailure, .noInternetAfterLogin,
    .httpStatus(503), .network("timed out"), .unknown,
]

private let allStates: [EngineState] = [
    .noWiFi, .checking, .online(campus: false), .online(campus: true), .notCampus, .portalDetected,
    .loggingIn, .connected(since: Date(timeIntervalSince1970: 0)), .needsCredentials, .keychainLocked,
] + allFailureReasons.map(EngineState.failed)

@Suite struct StatusCopyTests {
    @Test(arguments: allFailureReasons)
    func everyFailureHasATitleAndAdvice(_ reason: FailureReason) {
        #expect(!StatusCopy.title(for: reason).isEmpty)
        #expect(StatusCopy.advice(for: reason).count > 20)
    }

    @Test func theSpecifiedMessagesAreUsed() {
        #expect(StatusCopy.advice(for: .sessionLimit)
            == "Too many devices signed in. Log out elsewhere, or set Private Wi-Fi Address to Fixed.")
        #expect(StatusCopy.advice(for: .dnsFailure)
            == "Can't reach the login server. Turn off any custom DNS or VPN and try again.")
        #expect(StatusCopy.advice(for: .noInternetAfterLogin)
            == "Signed in, but the internet didn't come up. Try again in a minute.")
        #expect(StatusCopy.title(for: .failed(.wrongCredentials)) == "Wrong password")
        #expect(StatusCopy.title(for: .notCampus) == "Not on VIT Wi-Fi")
        // This state also covers Wi-Fi that is on but has not joined a network yet,
        // as just after the Mac starts up, so it must not claim that Wi-Fi is off.
        #expect(StatusCopy.title(for: .noWiFi) == "Not connected to Wi-Fi")
        #expect(StatusCopy.title(for: .loggingIn) == "Signing in…")
    }

    @Test(arguments: allStates)
    func everyStateHasATitle(_ state: EngineState) {
        #expect(!StatusCopy.title(for: state).isEmpty)
    }

    @Test func connectedShowsHowLong() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        func title(after seconds: TimeInterval) -> String {
            StatusCopy.connectedTitle(since: since, now: since.addingTimeInterval(seconds))
        }
        #expect(title(after: 0) == "Connected")
        #expect(title(after: 59) == "Connected")
        #expect(title(after: 60) == "Connected · 1m")
        #expect(title(after: 12 * 60 + 30) == "Connected · 12m")
        #expect(title(after: 3600) == "Connected · 1h 0m")
        #expect(title(after: 3600 + 12 * 60) == "Connected · 1h 12m")
        #expect(title(after: 26 * 3600 + 5 * 60) == "Connected · 26h 5m")
        // A clock that jumped backwards must not show nonsense.
        #expect(title(after: -500) == "Connected")
    }
}

@Suite struct StatusIconTests {
    private func appearance(_ state: EngineState) -> StatusIcon.Appearance {
        StatusIcon.Appearance(state: state)
    }

    @Test func iconsFollowTheState() {
        #expect(appearance(.connected(since: Date())).symbol == "wifi")
        #expect(appearance(.connected(since: Date())).treatment == .normal)
        #expect(appearance(.checking).treatment == .pulsing)
        #expect(appearance(.loggingIn).treatment == .pulsing)
        #expect(appearance(.loggingIn).symbol == "wifi")
        #expect(appearance(.noWiFi).symbol == "wifi.slash")
        #expect(appearance(.notCampus).treatment == .dimmed)
        #expect(appearance(.online(campus: false)).treatment == .dimmed)
        #expect(appearance(.online(campus: true)).symbol == "wifi")
    }

    @Test(arguments: [EngineState.needsCredentials, .portalDetected, .keychainLocked] + allFailureReasons.map(EngineState.failed))
    func anythingNeedingAttentionShowsTheWarningIcon(_ state: EngineState) {
        #expect(appearance(state).symbol == "wifi.exclamationmark")
        #expect(appearance(state).treatment == .normal)
    }
}

@Suite struct NotificationContentTests {
    @Test func connected() {
        let content = NotificationContent(.connected)
        #expect(content.category == .connected)
        #expect(content.title == "Connected")
    }

    @Test(arguments: allFailureReasons)
    func aFailedSignInUsesTheFailureCopy(_ reason: FailureReason) {
        let content = NotificationContent(.loginFailed(reason, afterSessionExpiry: false))
        #expect(content.category == .loginFailed)
        #expect(content.title == StatusCopy.title(for: reason))
        #expect(content.body == StatusCopy.advice(for: reason))
    }

    @Test func aFailedReloginHasItsOwnCategory() {
        let content = NotificationContent(.loginFailed(.accountExpired, afterSessionExpiry: true))
        #expect(content.category == .reloginFailed)
        #expect(content.title == "Session expired")
        #expect(content.body.contains(StatusCopy.advice(for: .accountExpired)))
    }

    @Test func loggedOut() {
        #expect(NotificationContent(.loggedOut(nil)).category == .loggedOut)
        #expect(NotificationContent(.loggedOut(nil)).body == "Signed out of VIT Wi-Fi.")
        let session = PortalSession(
            loginTime: Date(timeIntervalSince1970: 0), logoutTime: Date(timeIntervalSince1970: 60),
            duration: 60, uploadBytes: 10, downloadBytes: 20
        )
        #expect(NotificationContent(.loggedOut(session)).body == StatusCopy.summary(of: session))
    }

    @Test func keychainApprovalCountsAsAFailedSignIn() {
        let content = NotificationContent(.keychainApprovalNeeded)
        #expect(content.category == .loginFailed)
        #expect(content.body.contains("Unlock"))
    }

    @Test func noNotificationEverContainsCredentials() {
        // Notification text is built only from states and sessions, never from credentials.
        let events: [NotificationEvent] = [.connected, .keychainApprovalNeeded, .loggedOut(nil)]
            + allFailureReasons.flatMap { [.loginFailed($0, afterSessionExpiry: false), .loginFailed($0, afterSessionExpiry: true)] }
        for event in events {
            let content = NotificationContent(event)
            #expect(!content.title.contains("25BIT0088"))
            #expect(!content.body.contains("25BIT0088"))
        }
    }
}

@Suite struct SupportTests {
    @Test @MainActor func launchAtLoginIsOnlyOfferedFromAnApplicationsFolder() {
        #expect(LoginItem.isInstalled(at: "/Applications/Match.app"))
        #expect(LoginItem.isInstalled(at: "/Users/someone/Applications/Match.app", home: "/Users/someone"))
        #expect(!LoginItem.isInstalled(at: "/Users/someone/code/Match/build/Debug/Match.app", home: "/Users/someone"))
        #expect(!LoginItem.isInstalled(at: "/Users/someone/Downloads/Match.app", home: "/Users/someone"))
        #expect(!LoginItem.isInstalled(at: "/Volumes/Match/Match.app", home: "/Users/someone"))
    }

    @Test func diagnosticsRedactSecrets() {
        let text = "user 25BIT0088 signed in; again 25bit0088; nothing else"
        #expect(Diagnostics.redact(text, secrets: ["25BIT0088"]) == "user <redacted> signed in; again <redacted>; nothing else")
        #expect(Diagnostics.redact(text, secrets: []) == text)
        #expect(Diagnostics.redact(text, secrets: [""]) == text)
    }

    @Test func diagnosticsReportCarriesTheRecentLogWithSecretsRemoved() {
        let history = LogHistory(limit: 200)
        history.record(category: "engine", message: "state: checking")
        history.record(category: "portal", message: "sign-in for 25BIT0088: HTTP 200")
        let report = Diagnostics.report(state: .checking, secrets: ["25BIT0088"], history: history)
        #expect(report.contains("[engine] state: checking"))
        #expect(report.contains("[portal] sign-in for <redacted>: HTTP 200"))
        #expect(!report.contains("25BIT0088"))
    }

    @Test func diagnosticsSayWhenThereIsNothingYet() {
        let report = Diagnostics.report(state: .noWiFi, secrets: [], history: LogHistory(limit: 200))
        #expect(report.contains("(nothing has been logged yet)"))
    }

    @Test func everyLogCallLandsInTheHistory() {
        let marker = "history-probe-\(UUID().uuidString)"
        Log.ui.debug(marker)
        Log.ui.error(marker)
        let lines = LogHistory.shared.recent.filter { $0.contains(marker) }
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("[ui] error: \(marker)") })
    }

    @Test func theHistoryKeepsOnlyTheMostRecentLines() {
        let history = LogHistory(limit: 3)
        for index in 1...10 {
            history.record(category: "engine", message: "line \(index)")
        }
        #expect(history.recent.count == 3)
        #expect(history.recent.last?.hasSuffix("line 10") == true)
        #expect(history.recent.first?.hasSuffix("line 8") == true)
    }

    @Test func diagnosticsHeaderNamesTheState() {
        let header = Diagnostics.header(state: .failed(.sessionLimit)).joined(separator: "\n")
        #expect(header.contains("MAtCh "))
        #expect(header.contains("macOS "))
        #expect(header.contains("sessionLimit"))
    }
}

@Suite struct ExtendedSettingsTests {
    private func makeStore() throws -> (SettingsStore, UserDefaults, String) {
        let suite = "\(AppIdentity.bundleID).tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    @Test func defaults() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.campusNetworkNames == ["VIT"])
        #expect(!store.showNetworkName)
        #expect(store.keychainApprovedBuild == nil)
        for category in NotificationCategory.allCases {
            #expect(store.isNotificationEnabled(category))
        }
    }

    @Test func notificationCategoriesAreIndependent() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setNotification(.connected, enabled: false)
        #expect(!store.isNotificationEnabled(.connected))
        #expect(store.isNotificationEnabled(.loginFailed))
        #expect(store.isNotificationEnabled(.reloginFailed))
        #expect(store.isNotificationEnabled(.loggedOut))
    }

    @Test func campusNamesAreCleaned() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setCampusNetworkNames(["  VIT ", "vit", "", "Hostel", "   "])
        #expect(store.campusNetworkNames == ["VIT", "Hostel"])
        store.setCampusNetworkNames([])
        #expect(store.campusNetworkNames.isEmpty)
    }

    @Test func approvalRecordRoundTrips() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setKeychainApprovedBuild("abc")
        #expect(store.keychainApprovedBuild == "abc")
        store.setKeychainApprovedBuild(nil)
        #expect(store.keychainApprovedBuild == nil)
    }

    @Test func resetRestoresEveryDefault() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setAutoLoginEnabled(false)
        store.rememberCampusGateway("10.0.0.1")
        store.setCampusNetworkNames(["Elsewhere"])
        store.setShowNetworkName(true)
        store.setNotification(.loggedOut, enabled: false)
        store.setKeychainApprovedBuild("abc")

        store.resetAll()
        #expect(store.autoLoginEnabled)
        #expect(store.knownCampusGateways.isEmpty)
        #expect(store.campusNetworkNames == ["VIT"])
        #expect(!store.showNetworkName)
        #expect(store.isNotificationEnabled(.loggedOut))
        #expect(store.keychainApprovedBuild == nil)
    }

    @Test func forgettingGateways() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.rememberCampusGateway("10.0.0.1")
        store.forgetCampusGateways()
        #expect(store.knownCampusGateways.isEmpty)
    }
}
