import Foundation
import Network
import os

enum NetworkEvent: Equatable, Sendable {
    case wifiUp(interface: String, gateway: String?)
    case wifiDown
    case didWake
}

protocol NetworkEventSource: Sendable {
    func events() -> AsyncStream<NetworkEvent>
}

/// Watches the Wi-Fi interface and reports when it comes up, changes or goes down.
struct NetworkMonitor: NetworkEventSource {
    func events() -> AsyncStream<NetworkEvent> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            let lastEvent = OSAllocatedUnfairLock<NetworkEvent?>(initialState: nil)

            monitor.pathUpdateHandler = { path in
                let event = Self.event(for: path)
                let isNew = lastEvent.withLock { last in
                    guard last != event else { return false }
                    last = event
                    return true
                }
                guard isNew else { return }
                Log.network.debug("network: \(String(describing: event), privacy: .public)")
                continuation.yield(event)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "\(AppIdentity.bundleID).network-monitor"))
        }
    }

    /// Captive networks often report `.requiresConnection`, so that counts as up too.
    static func event(for path: NWPath) -> NetworkEvent {
        guard path.status == .satisfied || path.status == .requiresConnection else {
            return .wifiDown
        }
        let interface = path.availableInterfaces.first { $0.type == .wifi }?.name ?? "wifi"
        return .wifiUp(interface: interface, gateway: gateway(in: path.gateways))
    }

    /// The first IPv4 gateway, in dotted form.
    static func gateway(in gateways: [NWEndpoint]) -> String? {
        for endpoint in gateways {
            if case .hostPort(host: .ipv4(let address), port: _) = endpoint {
                return address.rawValue.map(String.init).joined(separator: ".")
            }
        }
        return nil
    }
}
