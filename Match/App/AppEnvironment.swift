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
        // A check of the vault that can be run from Terminal on a signed build:
        //   Match --vault-check save|load|clear
        if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: Self.vaultCheckArgument) {
            let arguments = ProcessInfo.processInfo.arguments
            Self.checkVault(arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "load")
            exit(0)
        }

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
        // The sign-in lives in the vault. Versions from before the vault kept it in an
        // item of the app's own, which is moved across the first time it is read.
        let suffix = usingMockPortal ? ".mock" : ""
        let credentials = VaultCredentialStore(
            vault: VaultClient(),
            service: VaultCredentialStore.defaultService + suffix,
            legacy: KeychainStore(service: KeychainStore.defaultService + suffix, approvals: settings)
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        // The update check uses its own client, and never the mock portal's address.
        let updateChecker = ReleaseSource.bundled.map {
            UpdateChecker(http: URLSessionHTTPClient(), source: $0, currentVersion: version)
        }

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
            updateChecker: updateChecker,
            usingMockPortal: usingMockPortal
        )

        // The uninstaller runs the app with this argument so that it can remove what
        // only it is allowed to remove, and then exits before anything else starts.
        if ProcessInfo.processInfo.arguments.contains(Self.uninstallArgument) {
            Self.cleanUpForUninstall(credentials: credentials, settings: settings, sessions: sessions)
            exit(0)
        }

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
        if !appState.usingMockPortal {
            appState.startUpdateSchedule()
        }
        if appState.savedUserId == nil {
            // Wait for the app to finish launching before putting a window on screen.
            Task { [appState] in
                try? await Task.sleep(for: .milliseconds(400))
                appState.showOnboarding()
            }
        }
    }

    static let uninstallArgument = "--uninstall-cleanup"
    static let vaultCheckArgument = "--vault-check"

    /// Exercises the vault with an item of its own, never the real sign-in.
    private static func checkVault(_ operation: String) {
        let vault = VaultClient()
        let service = VaultInfo.allowedServicePrefix + ".check"
        do {
            switch operation {
            case "save":
                try vault.save(Credentials(userId: "CHECK", password: "check-\(BuildIdentity.current.prefix(8))"), service: service)
                print("vault-check save: ok")
            case "clear":
                try vault.clear(service: service)
                print("vault-check clear: ok")
            default:
                let found = try vault.load(service: service)
                print("vault-check load: \(found == nil ? "nothing saved" : "found an item saved by build \(found?.password.dropFirst(6) ?? "?")")")
            }
            print("vault version \(try vault.version()), asked by build \(BuildIdentity.current.prefix(8))")
        } catch {
            print("vault-check \(operation): FAILED: \(error)")
        }
    }

    private static func cleanUpForUninstall(
        credentials: any CredentialStore, settings: SettingsStore, sessions: SessionStore
    ) {
        do {
            try credentials.clear()
            print("Removed the saved sign-in from the Keychain.")
        } catch {
            print("Could not remove the saved sign-in from the Keychain: \((error as? KeychainError)?.message ?? "\(error)")")
        }
        if LoginItem.isEnabled {
            try? LoginItem.setEnabled(false)
            print("Turned off launch at login.")
        }
        sessions.clear()
        settings.resetAll()
        print("Removed settings and history.")
    }

    static var isHostingTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }
}
