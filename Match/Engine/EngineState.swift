import Foundation

enum FailureReason: Equatable, Sendable {
    case wrongCredentials
    case accountExpired
    case sessionLimit
    case dnsFailure
    case noInternetAfterLogin
    case httpStatus(Int)
    case network(String)
    case unknown
}

enum EngineState: Equatable, Sendable {
    case noWiFi
    /// Probing.
    case checking
    /// The internet works. `campus` is true only after a manual sign-out left us
    /// online on a known campus network.
    case online(campus: Bool)
    /// A captive portal that is not VIT's. We do nothing.
    case notCampus
    /// The VIT portal is in the way and we are deliberately not signing in:
    /// auto-login is off, or the user signed out by hand.
    case portalDetected
    case loggingIn
    /// Signed in to the portal, and the internet works.
    case connected(since: Date)
    case needsCredentials
    /// A sign-in is saved, but macOS wants the user's approval before this build may
    /// read it. Only the user asking (Unlock or Connect) may bring up that dialog.
    case keychainLocked
    case failed(FailureReason)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
