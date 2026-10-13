import Foundation
import Observation

/// Receives the sessions the portal reports when signing out.
protocol SessionRecording: Sendable {
    func record(_ session: PortalSession) async
}

/// Keeps reported sessions in memory for the menu to show.
@MainActor
@Observable
final class SessionStore: SessionRecording {
    private(set) var sessions: [PortalSession] = []

    var latest: PortalSession? { sessions.last }

    func record(_ session: PortalSession) {
        sessions.append(session)
    }
}
