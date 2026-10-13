import Foundation

/// Builds the app's object graph and connects the system's events to the engine.
@MainActor
final class AppEnvironment {
    let appState: AppState
    private let engine: MatchEngine
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
        let credentials = KeychainStore(
            service: usingMockPortal ? KeychainStore.defaultService + ".mock" : KeychainStore.defaultService
        )
        let mockDefaults = usingMockPortal ? UserDefaults(suiteName: "\(AppIdentity.bundleID).mock") : nil
        let settings = SettingsStore(defaults: mockDefaults ?? .standard)
        let sessions = SessionStore()

        engine = MatchEngine(
            detector: PortalDetector(http: http, endpoints: endpoints),
            client: ProntoClient(http: http, endpoints: endpoints),
            credentials: credentials,
            settings: settings,
            notifier: SilentNotifier(),
            sessions: sessions
        )
        appState = AppState(
            engine: engine,
            credentials: credentials,
            settings: settings,
            sessions: sessions,
            usingMockPortal: usingMockPortal
        )

        // When the app is only hosting the unit tests it must stay inert.
        if !Self.isHostingTests {
            start(sources: [NetworkMonitor(), WakeObserver()])
        }
    }

    private func start(sources: [any NetworkEventSource]) {
        appState.start()
        for source in sources {
            forwarding.append(Task { [engine] in
                for await event in source.events() {
                    await engine.handle(event)
                }
            })
        }
    }

    static var isHostingTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }
}
