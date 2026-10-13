import CoreLocation
import CoreWLAN
import Foundation
import Observation

/// Supplies the name of the current Wi-Fi network, when it can be read.
protocol NetworkNaming: Sendable {
    func currentNetworkName() -> String?
}

/// Reads the Wi-Fi name. macOS only reveals it to apps with Location permission, so
/// this often returns `nil`, and that is fine: the name is used for display and for
/// recognising campus networks, never to decide whether to sign in.
struct WiFiInfo: NetworkNaming {
    func currentNetworkName() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// The Wi-Fi interface's system name, such as `en0`. Needs no permission.
    static var interfaceName: String {
        CWWiFiClient.shared().interface()?.interfaceName ?? "en0"
    }
}

/// Never knows the network name.
struct NoNetworkName: NetworkNaming {
    func currentNetworkName() -> String? { nil }
}

extension NetworkNaming {
    /// True when the current network's name contains one of `fragments`, ignoring case.
    func currentNetworkMatches(_ fragments: [String]) -> Bool {
        guard let name = currentNetworkName()?.lowercased(), !name.isEmpty else { return false }
        return fragments.contains { !$0.isEmpty && name.contains($0.lowercased()) }
    }
}

/// The Location permission, which macOS requires before it reveals the Wi-Fi name.
@MainActor
@Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isGranted: Bool {
        status == .authorizedAlways || status == .authorized
    }

    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    func request() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        Task { @MainActor in
            self.status = newStatus
        }
    }
}
