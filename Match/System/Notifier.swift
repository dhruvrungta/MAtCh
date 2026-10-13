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
            body = "Match couldn't sign back in. \(StatusCopy.advice(for: reason))"
        case .keychainApprovalNeeded:
            category = .loginFailed
            title = "Match needs your approval"
            body = "Open Match and click Unlock so it can use your saved sign-in."
        case .loggedOut(let session):
            category = .loggedOut
            title = "Logged out"
            body = session.map(StatusCopy.summary) ?? "Signed out of VIT Wi-Fi."
        }
    }
}

/// Posts notifications through the system, respecting the per-category settings.
struct UserNotifier: Notifying {
    let settings: SettingsStore

    func notify(_ event: NotificationEvent) async {
        let content = NotificationContent(event)
        guard settings.isNotificationEnabled(content.category) else { return }
        await Self.post(content)
    }

    @MainActor
    private static func post(_ content: NotificationContent) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        // One identifier per category, so a newer notification replaces the older one
        // instead of piling up.
        let request = UNNotificationRequest(identifier: content.category.rawValue, content: notification, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            Log.ui.error("could not post a notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks the user for permission. Call this from onboarding or Settings, never at launch.
    @MainActor
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.ui.error("notification permission request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @MainActor
    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
}
