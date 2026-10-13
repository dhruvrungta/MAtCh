import AppKit
import Foundation

/// Builds the app's object graph and connects the system's events to the engine.
@MainActor
final class AppEnvironment {
    let appState: AppState
    private let engine: MatchEngine
    private let onboarding = OnboardingWindow()
    private var forwarding: [Task<Void, Never>] = []

    init() {
        let endpoints = PortalEndpoints.resolve(
            arguments: ProcessInfo.processInfo.arguments,
            isDebugBuild: PortalEndpoints.isDebugBuild
        )
        // A debug build pointed at the mock portal keeps its own sign-in and settings,
        // so real credentials never reach a mock and test ones never reach the real portal.
        let usingMockPortal = endpoints != .production
        let http = URLSessionHTTPClient()
        let mockDefaults = usingMockPortal ? UserDefaults(suiteName: "\(AppIdentity.bundleID).mock") : nil
        let settings = SettingsStore(defaults: mockDefaults ?? .standard)
        let credentials = KeychainStore(
            service: usingMockPortal ? KeychainStore.defaultService + ".mock" : KeychainStore.defaultService,
            approvals: settings
        )
        // The app keeps no history file while it is only hosting the unit tests.
        let historyFile = Self.isHostingTests
            ? nil
            : SessionStore.defaultFileURL(name: usingMockPortal ? "sessions.mock.json" : "sessions.json")
        let sessions = SessionStore(fileURL: historyFile)
        let usage = UsageMonitor(
            counters: InterfaceCounters(),
            interface: { WiFiInfo.interfaceName },
            sessions: sessions
        )
        let networkNames = WiFiInfo()

        engine = MatchEngine(
            detector: PortalDetector(http: http, endpoints: endpoints),
            client: ProntoClient(http: http, endpoints: endpoints),
            credentials: credentials,
            settings: settings,
            notifier: UserNotifier(settings: settings),
            sessions: sessions,
            networkNames: networkNames
        )
        appState = AppState(
            engine: engine,
            credentials: credentials,
            settings: settings,
            sessions: sessions,
            usage: usage,
            networkNames: networkNames,
            usingMockPortal: usingMockPortal
        )
        appState.showOnboarding = { [weak self] in
            guard let self else { return }
            onboarding.show(appState: appState)
        }

        // When the app is only hosting the unit tests it must stay inert.
        if !Self.isHostingTests {
            start(sources: [NetworkMonitor(), WakeObserver()])
        }
    }

    private func start(sources: [any NetworkEventSource]) {
        NotificationPresenter.install()
        appState.start()
        // Close the session being measured when the app quits, so it reaches the history.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [usage = appState.usage] _ in
            MainActor.assumeIsolated { usage.flush() }
        }
        for source in sources {
            forwarding.append(Task { [engine] in
                for await event in source.events() {
                    await engine.handle(event)
                }
            })
        }
        if appState.savedUserId == nil {
            // Wait for the app to finish launching before putting a window on screen.
            Task { [appState] in
                try? await Task.sleep(for: .milliseconds(400))
                appState.showOnboarding()
            }
        }
    }

    static var isHostingTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }
}
