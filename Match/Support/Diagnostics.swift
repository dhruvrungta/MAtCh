import Foundation
import OSLog

/// Builds the text behind "Copy diagnostics".
enum Diagnostics {
    static let lineLimit = 200

    /// The app's own recent log lines, with `secrets` blanked out.
    static func report(state: EngineState, secrets: [String]) -> String {
        var lines = header(state: state)
        do {
            lines += try recentLogLines()
        } catch {
            lines.append("(the log could not be read: \(error.localizedDescription))")
        }
        return redact(lines.joined(separator: "\n"), secrets: secrets)
    }

    static func header(state: EngineState) -> [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return [
            "Match \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "State: \(state)",
            "---",
        ]
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        secrets
            .filter { !$0.isEmpty }
            .reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>", options: .caseInsensitive) }
    }

    private static func recentLogLines() throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", AppIdentity.bundleID)
        let entries = try store.getEntries(matching: predicate)
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
        }
        return Array(lines.suffix(lineLimit))
    }
}
