import Foundation

/// The moments worth telling the user about. Routine health checks are never one of them.
enum NotificationEvent: Equatable, Sendable {
    /// A sign-in succeeded and the internet came up.
    case connected
    /// A sign-in was attempted and did not work.
    case loginFailed(FailureReason, afterSessionExpiry: Bool)
    case loggedOut(PortalSession?)
}

protocol Notifying: Sendable {
    func notify(_ event: NotificationEvent) async
}

/// Posts nothing.
struct SilentNotifier: Notifying {
    func notify(_ event: NotificationEvent) async {}
}
