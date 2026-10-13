import AppKit

/// Reports when the Mac wakes from sleep.
struct WakeObserver: NetworkEventSource {
    func events() -> AsyncStream<NetworkEvent> {
        AsyncStream { continuation in
            let center = NSWorkspace.shared.notificationCenter
            let token = ObserverToken(
                center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
                    continuation.yield(.didWake)
                }
            )
            continuation.onTermination = { _ in
                center.removeObserver(token.value)
            }
        }
    }
}

/// Carries the observation token into the stream's termination handler. The token is
/// only ever handed back to the notification center, which is safe from any thread.
private struct ObserverToken: @unchecked Sendable {
    let value: any NSObjectProtocol

    init(_ value: any NSObjectProtocol) {
        self.value = value
    }
}
