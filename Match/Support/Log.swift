import Foundation
import os

enum AppIdentity {
    /// The bundle identifier is defined once, in `project.yml`. The literal is only a
    /// fallback for contexts that have no main bundle identifier.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.dhruvrungta.match"
}

/// Log categories.
///
/// Every message goes to the system log and into a short in-memory history, which is
/// what "Copy diagnostics" hands to the user. So a message must be safe to show:
/// never pass a password or a registration number to any of these.
enum Log {
    static let engine = Channel("engine")
    static let network = Channel("network")
    static let portal = Channel("portal")
    static let storage = Channel("storage")
    static let ui = Channel("ui")

    struct Channel: Sendable {
        let category: String
        private let logger: Logger

        init(_ category: String) {
            self.category = category
            logger = Logger(subsystem: AppIdentity.bundleID, category: category)
        }

        func debug(_ message: String) {
            logger.debug("\(message, privacy: .public)")
            LogHistory.shared.record(category: category, message: message)
        }

        func error(_ message: String) {
            logger.error("\(message, privacy: .public)")
            LogHistory.shared.record(category: category, message: "error: \(message)")
        }
    }
}

/// The most recent log lines, kept in memory only.
///
/// The system's own log store does not hand debug-level messages back to the app that
/// wrote them, so diagnostics are built from this instead.
final class LogHistory: Sendable {
    static let shared = LogHistory(limit: 200)

    private let limit: Int
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    init(limit: Int) {
        self.limit = limit
    }

    func record(category: String, message: String, at date: Date = Date()) {
        let line = "\(date.formatted(.iso8601)) [\(category)] \(message)"
        lines.withLock { lines in
            lines.append(line)
            if lines.count > limit {
                lines.removeFirst(lines.count - limit)
            }
        }
    }

    var recent: [String] { lines.withLock { $0 } }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
