import Foundation

/// One portal session, as reported by the portal when signing out.
struct PortalSession: Equatable, Sendable, Codable {
    var loginTime: Date
    var logoutTime: Date
    /// Seconds.
    var duration: TimeInterval
    var uploadBytes: Int64
    var downloadBytes: Int64
}

/// Reads the usage figures out of the portal's sign-out page.
enum LogoutParser {
    static func parse(_ html: String, logoutTime: Date = Date()) -> PortalSession? {
        let timeSpent = #/Time\s+Spent\s*:\s*(\d+)\s*H\s*:\s*(\d+)\s*M\s*:\s*(\d+)\s*S/#
            .ignoresCase().asciiOnlyDigits().asciiOnlyWhitespace()
        let bytesSent = #/Bytes\s+Sent\s*:\s*(\d+)/#
            .ignoresCase().asciiOnlyDigits().asciiOnlyWhitespace()
        let bytesReceived = #/Bytes\s+Received\s*:\s*(\d+)/#
            .ignoresCase().asciiOnlyDigits().asciiOnlyWhitespace()

        guard let time = html.firstMatch(of: timeSpent) else { return nil }
        let hours = Double(time.output.1) ?? 0
        let minutes = Double(time.output.2) ?? 0
        let seconds = Double(time.output.3) ?? 0
        let duration = hours * 3600 + minutes * 60 + seconds

        let upload = html.firstMatch(of: bytesSent).flatMap { Int64($0.output.1) } ?? 0
        let download = html.firstMatch(of: bytesReceived).flatMap { Int64($0.output.1) } ?? 0

        let epoch = Date(timeIntervalSince1970: 0)
        let loginTime = max(logoutTime.addingTimeInterval(-duration), epoch)

        return PortalSession(
            loginTime: loginTime,
            logoutTime: logoutTime,
            duration: duration,
            uploadBytes: upload,
            downloadBytes: download
        )
    }
}
