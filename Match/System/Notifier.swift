import Foundation
import UserNotifications

/// The moments worth telling the user about. Routine health checks are never one of them.
enum NotificationEvent: Equatable, Sendable {
    /// A sign-in succeeded and the internet came up.
    case connected
    /// A sign-in was attempted and did not work.
    case loginFailed(FailureReason, afterSessionExpiry: Bool)
    /// A sign-in was needed, but macOS wants the user's approval to read the saved one.
    case keychainApprovalNeeded
    case loggedOut(PortalSession?)
}

protocol Notifying: Sendable {
    func notify(_ event: NotificationEvent) async
}

/// Posts nothing.
struct SilentNotifier: Notifying {
    func notify(_ event: NotificationEvent) async {}
}

/// What a notification says, and which setting switches it off.
struct NotificationContent: Equatable, Sendable {
    var category: NotificationCategory
    var title: String
    var body: String

    init(_ event: NotificationEvent) {
        switch event {
        case .connected:
            category = .connected
            title = "Connected"
            body = "Signed in to VIT Wi-Fi."
        case .loginFailed(let reason, afterSessionExpiry: false):
            category = .loginFailed
            title = StatusCopy.title(for: reason)
            body = StatusCopy.advice(for: reason)
        case .loginFailed(let reason, afterSessionExpiry: true):
            category = .reloginFailed
            title = "Session expired"
            body = "MAtCh couldn't sign back in. \(StatusCopy.advice(for: reason))"
        case .keychainApprovalNeeded:
            category = .loginFailed
            title = "MAtCh needs your approval"
            body = "Open MAtCh and click Unlock so it can use your saved sign-in."
        case .loggedOut(let session):
            category = .loggedOut
            title = "Logged out"
            body = session.map(StatusCopy.summary) ?? "Signed out of VIT Wi-Fi."
        }
    }
}

/// Tells macOS to show Match's notifications even while Match is the active app.
///
/// Without this, a notification that arrives while the app is frontmost is handed to
/// the app instead of being shown. Match is frontmost exactly when it matters: just
/// after the user clicked Connect or Log out in its menu.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    @MainActor
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

/// Posts notifications through the system, respecting the per-category settings.
struct UserNotifier: Notifying {
    let settings: SettingsStore

    func notify(_ event: NotificationEvent) async {
        let content = NotificationContent(event)
        guard settings.isNotificationEnabled(content.category) else {
            Log.ui.debug("notification not posted, switched off: \(content.category.rawValue)")
            return
        }
        await Self.post(content)
    }

    @MainActor
    private static func post(_ content: NotificationContent) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            Log.ui.debug("notification not posted, macOS permission is \(status.rawValue): \(content.category.rawValue)")
            return
        }

        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        // Clear Match's older notifications so they don't pile up, then post this one
        // under an identifier of its own. Reusing an identifier makes macOS update the
        // old notification in place, which does not bring up a banner again.
        center.removeAllDeliveredNotifications()
        let identifier = "\(content.category.rawValue)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: notification, trigger: nil)
        do {
            try await center.add(request)
            Log.ui.debug("notification posted: \(content.category.rawValue)")
        } catch {
            Log.ui.error("could not post a notification: \(error.localizedDescription)")
        }
    }

    /// Asks the user for permission. Call this from onboarding or Settings, never at launch.
    @MainActor
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.ui.error("notification permission request failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
}
