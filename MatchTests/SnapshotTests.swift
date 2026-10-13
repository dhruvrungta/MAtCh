import AppKit
import os
import SwiftUI
import Testing
@testable import Match

/// Renders the app's screens to PNG images so they can be looked at without driving
/// the app by hand. Opt-in (`make snapshots`); it asserts only that every screen
/// renders at a sensible size.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MATCH_SNAPSHOTS"] != nil))
@MainActor
struct SnapshotTests {
    private func makeAppState(
        credentials: Credentials? = Credentials(userId: "25BIT0088", password: "pw"),
        needsApproval: Bool = false,
        networkName: String? = "T-VIT"
    ) throws -> AppState {
        let suite = "\(AppIdentity.bundleID).tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        settings.setShowNetworkName(networkName != nil)
        settings.rememberCampusGateway("172.17.104.1")
        let store = InMemoryCredentialStore(credentials, needsApproval: needsApproval)
        let portal = FakePortal()
        let sessions = SessionStore(fileURL: nil)
        let counters = SteppingCounters()
        // Each reading is taken two seconds after the last, so the speed shown is plausible.
        let readings = OSAllocatedUnfairLock(initialState: 0.0)
        let usage = UsageMonitor(counters: counters, interface: { "en0" }, sessions: sessions) {
            Date(timeIntervalSince1970: 1_800_000_000 + readings.withLock { value in
                value += 2
                return value
            })
        }
        let engine = MatchEngine(
            detector: PortalDetector(http: portal, endpoints: .test),
            client: ProntoClient(http: portal, endpoints: .test),
            credentials: store,
            settings: settings,
            notifier: SilentNotifier(),
            sessions: sessions
        )
        let appState = AppState(
            engine: engine,
            credentials: store,
            settings: settings,
            sessions: sessions,
            usage: usage,
            networkNames: FixedNetworkName(name: networkName),
            usingMockPortal: false
        )
        appState.refreshKeychainStatus()
        appState.refreshNetworkDetails()
        return appState
    }

    private func snapshot(_ view: some View, _ name: String) throws {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()

        let representation = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let data = try #require(representation.representation(using: .png, properties: [:]))
        // The test host is sandboxed and its container is closed to other processes,
        // so the image leaves through standard output.
        print("SNAPSHOT \(name) \(data.base64EncodedString())")
        #expect(hosting.bounds.width > 200)
        #expect(hosting.bounds.height > 80)
    }

    @Test func menu() throws {
        let appState = try makeAppState()
        let since = Date().addingTimeInterval(-4320)
        appState.engineState = .connected(since: since)
        appState.usage.connectionChanged(to: .connected(since: since))
        appState.usage.sample()
        try snapshot(MenuContentView(appState: appState), "menu-connected")
        appState.usage.connectionChanged(to: .noWiFi)

        appState.engineState = .failed(.sessionLimit)
        try snapshot(MenuContentView(appState: appState), "menu-failed")

        appState.engineState = .portalDetected
        try snapshot(MenuContentView(appState: appState), "menu-portal")

        let locked = try makeAppState(needsApproval: true)
        locked.engineState = .keychainLocked
        try snapshot(MenuContentView(appState: locked), "menu-locked")

        locked.engineState = .connected(since: Date().addingTimeInterval(-90))
        try snapshot(MenuContentView(appState: locked), "menu-unlock-reminder")

        let fresh = try makeAppState(credentials: nil, networkName: nil)
        fresh.engineState = .needsCredentials
        try snapshot(MenuContentView(appState: fresh), "menu-needs-credentials")
    }

    @Test func onboarding() throws {
        let appState = try makeAppState(credentials: nil)
        for step in 1...3 {
            try snapshot(OnboardingView(appState: appState, startingAt: step) {}, "onboarding-\(step)")
        }
    }

    @Test func settings() throws {
        let appState = try makeAppState()
        appState.engineState = .connected(since: Date())
        let tabs: [(AppState.SettingsTab, String)] = [
            (.general, "general"), (.account, "account"), (.network, "network"),
            (.advanced, "advanced"), (.about, "about"),
        ]
        for (tab, name) in tabs {
            appState.selectedSettingsTab = tab
            try snapshot(SettingsView(appState: appState), "settings-\(name)")
        }

        let locked = try makeAppState(needsApproval: true)
        locked.selectedSettingsTab = .account
        try snapshot(SettingsView(appState: locked), "settings-account-locked")

        appState.selectedSettingsTab = .history
        try snapshot(SettingsView(appState: appState), "settings-history-empty")
        let now = Date()
        appState.sessions.recordMeasured(
            start: now.addingTimeInterval(-9000), end: now.addingTimeInterval(-5400),
            downloadBytes: 734_003_200, uploadBytes: 41_943_040
        )
        appState.sessions.record(PortalSession(
            loginTime: now.addingTimeInterval(-3723), logoutTime: now, duration: 3723,
            uploadBytes: 12_582_912, downloadBytes: 1_288_490_188
        ))
        try snapshot(SettingsView(appState: appState), "settings-history")
    }
}
