import Foundation

/// The words Match uses for each state, shared by the menu and the notifications.
enum StatusCopy {
    static func title(for state: EngineState, now: Date = Date()) -> String {
        switch state {
        case .noWiFi: "Not connected to Wi-Fi"
        case .checking: "Checking…"
        case .online(let campus): campus ? "Signed out" : "Online"
        case .notCampus: "Not on VIT Wi-Fi"
        case .portalDetected: "Portal detected"
        case .loggingIn: "Signing in…"
        case .connected(let since): connectedTitle(since: since, now: now)
        case .needsCredentials: "Sign-in details needed"
        case .keychainLocked: "Match was updated"
        case .failed(let reason): title(for: reason)
        }
    }

    static func detail(for state: EngineState) -> String? {
        switch state {
        case .noWiFi: "Match will sign in as soon as this Mac joins the hostel Wi-Fi."
        case .checking, .loggingIn, .connected: nil
        case .online(let campus):
            campus
                ? "You logged out, but the internet still works. Click Connect any time."
                : "The internet works. Match signs in only on VIT Wi-Fi."
        case .notCampus: "This network has its own login page. Match leaves it alone."
        case .portalDetected: "Click Connect to sign in."
        case .needsCredentials: "Add your registration number and Wi-Fi password."
        case .keychainLocked: keychainApprovalAdvice
        case .failed(let reason): advice(for: reason)
        }
    }

    static let keychainApprovalAdvice =
        "macOS needs your approval before this version can use your saved sign-in. Click Unlock, then choose Always Allow."

    /// "Connected", then "Connected · 12m", then "Connected · 1h 12m".
    static func connectedTitle(since: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since)) / 60
        guard minutes >= 1 else { return "Connected" }
        let hours = minutes / 60
        return hours > 0 ? "Connected · \(hours)h \(minutes % 60)m" : "Connected · \(minutes)m"
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
            "The portal rejected your registration number or password. Update them in Settings and try again."
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
            "The network didn't respond (\(message)). Try again."
        case .unknown:
            "Something went wrong. Try again."
        }
    }

    static func summary(of session: PortalSession) -> String {
        summary(duration: session.duration, downloadBytes: session.downloadBytes, uploadBytes: session.uploadBytes)
    }

    static func summary(of record: SessionRecord) -> String {
        summary(duration: record.duration, downloadBytes: record.downloadBytes, uploadBytes: record.uploadBytes)
    }

    static func summary(duration: TimeInterval, downloadBytes: Int64, uploadBytes: Int64) -> String {
        "\(length(duration)) · ↓ \(bytes(downloadBytes)) · ↑ \(bytes(uploadBytes))"
    }

    static func length(_ duration: TimeInterval) -> String {
        Duration.seconds(duration.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .binary))
    }

    /// A speed in bytes per second, as "1.2 MB/s".
    static func speed(_ bytesPerSecond: Double) -> String {
        "\(bytes(Int64(max(0, bytesPerSecond).rounded())))/s"
    }
}
