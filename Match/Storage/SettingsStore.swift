import Foundation

/// The settings the engine reads and writes.
protocol EngineSettings: Sendable {
    var autoLoginEnabled: Bool { get }
    func setAutoLoginEnabled(_ enabled: Bool)

    /// Gateway addresses of networks where the VIT portal has been seen. Used only to
    /// tell "signed in on campus" from "online somewhere else"; never to decide
    /// whether credentials may be sent.
    var knownCampusGateways: Set<String> { get }
    func rememberCampusGateway(_ gateway: String)

    /// Fragments of Wi-Fi names that count as campus networks, for the same purpose.
    var campusNetworkNames: [String] { get }
}

enum NotificationCategory: String, CaseIterable, Sendable {
    case connected
    case loginFailed
    case reloginFailed
    case loggedOut

    var label: String {
        switch self {
        case .connected: "Signed in"
        case .loginFailed: "Sign-in failed"
        case .reloginFailed: "Session expired and couldn't sign back in"
        case .loggedOut: "Logged out"
        }
    }
}

/// `UserDefaults`-backed settings. Nothing secret is ever stored here.
final class SettingsStore: EngineSettings, KeychainApprovalRecord, @unchecked Sendable {
    // `UserDefaults` is documented as thread-safe, which is what makes this class
    // safe to share despite the unchecked conformance.
    private let defaults: UserDefaults

    private enum Key {
        static let autoLogin = "autoLoginEnabled"
        static let campusGateways = "knownCampusGateways"
        static let campusNetworkNames = "campusNetworkNames"
        static let showNetworkName = "showNetworkName"
        static let keychainApprovedBuild = "keychainApprovedBuild"
        static let updateChecks = "updateChecksEnabled"
        static let lastUpdateCheck = "lastUpdateCheck"
        static func notification(_ category: NotificationCategory) -> String { "notify.\(category.rawValue)" }

        static var all: [String] {
            [autoLogin, campusGateways, campusNetworkNames, showNetworkName, keychainApprovedBuild,
             updateChecks, lastUpdateCheck]
                + NotificationCategory.allCases.map(notification)
        }
    }

    static let maxRememberedGateways = 16
    static let defaultCampusNetworkNames = ["VIT"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var registered: [String: Any] = [
            Key.autoLogin: true,
            Key.campusNetworkNames: Self.defaultCampusNetworkNames,
            Key.showNetworkName: false,
            Key.updateChecks: true,
        ]
        for category in NotificationCategory.allCases {
            registered[Key.notification(category)] = true
        }
        defaults.register(defaults: registered)
    }

    // MARK: Engine settings

    var autoLoginEnabled: Bool { defaults.bool(forKey: Key.autoLogin) }

    func setAutoLoginEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.autoLogin)
    }

    var knownCampusGateways: Set<String> { Set(gateways) }

    func rememberCampusGateway(_ gateway: String) {
        var list = gateways.filter { $0 != gateway }
        list.append(gateway)
        defaults.set(Array(list.suffix(Self.maxRememberedGateways)), forKey: Key.campusGateways)
    }

    func forgetCampusGateways() {
        defaults.removeObject(forKey: Key.campusGateways)
    }

    private var gateways: [String] { defaults.stringArray(forKey: Key.campusGateways) ?? [] }

    var campusNetworkNames: [String] {
        defaults.stringArray(forKey: Key.campusNetworkNames) ?? Self.defaultCampusNetworkNames
    }

    func setCampusNetworkNames(_ names: [String]) {
        var seen = Set<String>()
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        defaults.set(cleaned, forKey: Key.campusNetworkNames)
    }

    // MARK: Interface settings

    var showNetworkName: Bool { defaults.bool(forKey: Key.showNetworkName) }

    func setShowNetworkName(_ show: Bool) {
        defaults.set(show, forKey: Key.showNetworkName)
    }

    func isNotificationEnabled(_ category: NotificationCategory) -> Bool {
        defaults.bool(forKey: Key.notification(category))
    }

    func setNotification(_ category: NotificationCategory, enabled: Bool) {
        defaults.set(enabled, forKey: Key.notification(category))
    }

    // MARK: Keychain approval

    var keychainApprovedBuild: String? { defaults.string(forKey: Key.keychainApprovedBuild) }

    func setKeychainApprovedBuild(_ build: String?) {
        if let build {
            defaults.set(build, forKey: Key.keychainApprovedBuild)
        } else {
            defaults.removeObject(forKey: Key.keychainApprovedBuild)
        }
    }

    // MARK: Updates

    var updateChecksEnabled: Bool { defaults.bool(forKey: Key.updateChecks) }

    func setUpdateChecksEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.updateChecks)
    }

    var lastUpdateCheck: Date? { defaults.object(forKey: Key.lastUpdateCheck) as? Date }

    func setLastUpdateCheck(_ date: Date) {
        defaults.set(date, forKey: Key.lastUpdateCheck)
    }

    /// Puts every setting back to its default.
    func resetAll() {
        for key in Key.all {
            defaults.removeObject(forKey: key)
        }
    }
}
