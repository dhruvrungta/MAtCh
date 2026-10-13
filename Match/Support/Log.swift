import Foundation
import os

enum AppIdentity {
    /// The bundle identifier is defined once, in `project.yml`. The literal is only a
    /// fallback for contexts that have no main bundle identifier.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.dhruvrungta.match"
}

/// Log categories. Never pass a password to any of these, and mark the registration
/// number `privacy: .private`.
enum Log {
    static let engine = Logger(subsystem: AppIdentity.bundleID, category: "engine")
    static let network = Logger(subsystem: AppIdentity.bundleID, category: "network")
    static let portal = Logger(subsystem: AppIdentity.bundleID, category: "portal")
    static let storage = Logger(subsystem: AppIdentity.bundleID, category: "storage")
    static let ui = Logger(subsystem: AppIdentity.bundleID, category: "ui")
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
