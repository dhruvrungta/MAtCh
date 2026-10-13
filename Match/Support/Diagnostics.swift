import Foundation

/// Builds the text behind "Copy diagnostics".
enum Diagnostics {
    /// The app's recent activity, with `secrets` blanked out.
    static func report(state: EngineState, secrets: [String], history: LogHistory = .shared) -> String {
        var lines = header(state: state)
        let recent = history.recent
        lines += recent.isEmpty ? ["(nothing has been logged yet)"] : recent
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
}
