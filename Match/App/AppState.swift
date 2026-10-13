import Foundation
import Observation

/// What the UI shows. Mirrors the engine's state on the main actor and carries the
/// user's actions back to it.
@MainActor
@Observable
final class AppState {
    enum PrimaryAction: Equatable {
        case connect
        case logOut
        case addCredentials
        case tryAgain

        var title: String {
            switch self {
            case .connect: "Connect"
            case .logOut: "Log out"
            case .addCredentials: "Add credentials"
            case .tryAgain: "Try again"
            }
        }
    }

    private(set) var engineState: EngineState = .noWiFi
    private(set) var savedUserId: String?
    private(set) var autoLoginEnabled: Bool
    let sessions: SessionStore
    /// True when a debug build has been pointed at the mock portal.
    let usingMockPortal: Bool

    @ObservationIgnored private let engine: MatchEngine
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(
        engine: MatchEngine,
        credentials: any CredentialStore,
        settings: any EngineSettings,
        sessions: SessionStore,
        usingMockPortal: Bool
    ) {
        self.engine = engine
        self.credentials = credentials
        self.sessions = sessions
        self.usingMockPortal = usingMockPortal
        self.autoLoginEnabled = settings.autoLoginEnabled
    }

    func start() {
        do {
            savedUserId = try credentials.load()?.userId
        } catch {
            Log.storage.error("could not read the saved sign-in: \(String(describing: error), privacy: .public)")
        }
        observation = Task { [weak self, engine] in
            for await state in await engine.states {
                self?.engineState = state
            }
        }
    }

    // MARK: Actions

    func perform(_ action: PrimaryAction) {
        switch action {
        case .connect, .tryAgain:
            Task { await engine.connectNow() }
        case .logOut:
            Task { await engine.logout() }
        case .addCredentials:
            break
        }
    }

    func setAutoLogin(_ enabled: Bool) {
        autoLoginEnabled = enabled
        Task { await engine.setAutoLogin(enabled) }
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
            Log.storage.error("could not save the sign-in: \(String(describing: error), privacy: .public)")
            return "Couldn't save to the Keychain. \(Self.describe(error))"
        }
        savedUserId = normalized
        Task { await engine.credentialsChanged() }
        return nil
    }

    /// Returns a message for the user if the saved sign-in could not be removed.
    func removeCredentials() -> String? {
        do {
            try credentials.clear()
        } catch {
            Log.storage.error("could not remove the sign-in: \(String(describing: error), privacy: .public)")
            return "Couldn't remove the saved sign-in. \(Self.describe(error))"
        }
        savedUserId = nil
        return nil
    }

    private static func describe(_ error: any Error) -> String {
        (error as? KeychainError)?.message ?? error.localizedDescription
    }

    // MARK: Presentation

    var primaryAction: PrimaryAction? {
        switch engineState {
        case .connected: .logOut
        case .portalDetected: .connect
        case .needsCredentials: .addCredentials
        case .failed: .tryAgain
        case .noWiFi, .checking, .loggingIn, .online, .notCampus: nil
        }
    }

    var statusTitle: String {
        switch engineState {
        case .noWiFi: "Wi-Fi is off"
        case .checking: "Checking…"
        case .online(let campus): campus ? "Signed out" : "Online"
        case .notCampus: "Not on VIT Wi-Fi"
        case .portalDetected: "Portal detected"
        case .loggingIn: "Signing in…"
        case .connected: "Connected"
        case .needsCredentials: "Sign-in details needed"
        case .failed(let reason): Self.title(for: reason)
        }
    }

    var statusDetail: String? {
        switch engineState {
        case .noWiFi: "Turn on Wi-Fi and join the hostel network."
        case .checking, .loggingIn: nil
        case .online(let campus):
            campus
                ? "You signed out, but the internet still works. Click Connect any time."
                : "The internet works. Match signs in only on VIT Wi-Fi."
        case .notCampus: "This network has its own login page. Match leaves it alone."
        case .portalDetected: "Click Connect to sign in."
        case .connected(let since): "Since \(since.formatted(date: .omitted, time: .shortened))"
        case .needsCredentials: "Add your registration number and Wi-Fi password."
        case .failed(let reason): Self.advice(for: reason)
        }
    }

    var menuBarSymbol: String {
        switch engineState {
        case .connected, .checking, .loggingIn, .online, .notCampus: "wifi"
        case .failed, .needsCredentials, .portalDetected: "wifi.exclamationmark"
        case .noWiFi: "wifi.slash"
        }
    }

    static func title(for reason: FailureReason) -> String {
        switch reason {
        case .wrongCredentials: "Wrong password"
        case .accountExpired: "Account expired"
        case .sessionLimit: "Too many devices"
        case .dnsFailure: "Can't reach the login server"
        case .noInternetAfterLogin: "No internet after signing in"
        case .httpStatus, .network, .unknown: "Couldn't sign in"
        }
    }

    static func advice(for reason: FailureReason) -> String {
        switch reason {
        case .wrongCredentials:
            "The portal rejected your registration number or password. Update them and try again."
        case .accountExpired:
            "The portal says your account has expired. Contact the hostel network office."
        case .sessionLimit:
            "Too many devices signed in. Log out elsewhere, or set Private Wi-Fi Address to Fixed."
        case .dnsFailure:
            "Can't reach the login server. Turn off any custom DNS or VPN and try again."
        case .noInternetAfterLogin:
            "Signed in, but the internet didn't come up. Try again in a minute."
        case .httpStatus(let status):
            "The portal answered with an error (HTTP \(status)). Try again in a minute."
        case .network(let message):
            "The network didn't respond: \(message). Try again."
        case .unknown:
            "Something went wrong. Try again."
        }
    }
}
