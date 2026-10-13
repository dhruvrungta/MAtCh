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
}

/// `UserDefaults`-backed settings. Nothing secret is ever stored here.
final class SettingsStore: EngineSettings, @unchecked Sendable {
    // `UserDefaults` is documented as thread-safe, which is what makes this class
    // safe to share despite the unchecked conformance.
    private let defaults: UserDefaults

    private enum Key {
        static let autoLogin = "autoLoginEnabled"
        static let campusGateways = "knownCampusGateways"
    }

    static let maxRememberedGateways = 16

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.autoLogin: true])
    }

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

    private var gateways: [String] { defaults.stringArray(forKey: Key.campusGateways) ?? [] }
}
