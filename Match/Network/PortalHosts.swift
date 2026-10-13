import Foundation

/// The single source of truth for the hosts Match is allowed to talk to.
enum PortalHosts {
    static let portal = "phc.prontonetworks.com"
    static let vit: Set<String> = [portal, "136.233.9.110"]
    static let probeURL = URL(string: "http://clients3.google.com/generate_204")!
    static let portalBase = URL(string: "http://\(portal)")!
}

/// Where the probe and the portal live. Production values come from `PortalHosts`;
/// tests and the debug-only mock override substitute their own.
struct PortalEndpoints: Equatable, Sendable {
    var probeURL: URL
    var portalBase: URL
    /// Hosts that count as "the VIT portal" when the probe is intercepted.
    var vitHosts: Set<String>

    static let production = PortalEndpoints(
        probeURL: PortalHosts.probeURL,
        portalBase: PortalHosts.portalBase,
        vitHosts: PortalHosts.vit
    )

    func isVITHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return vitHosts.contains(host.lowercased())
    }

    /// The portal base with its host swapped for `host` (the Wi-Fi gateway), keeping
    /// the scheme and port.
    func base(host: String?) -> URL {
        guard let host, var components = URLComponents(url: portalBase, resolvingAgainstBaseURL: false) else {
            return portalBase
        }
        components.host = host
        return components.url ?? portalBase
    }

    /// The endpoints to use for this launch. Only debug builds honour the mock-portal
    /// launch argument, and only when it points at this machine.
    static func resolve(arguments: [String], isDebugBuild: Bool) -> PortalEndpoints {
        guard isDebugBuild, let base = mockPortalBase(in: arguments) else { return .production }
        return mock(base: base)
    }

    static func mock(base: URL) -> PortalEndpoints {
        var hosts = PortalHosts.vit
        if let host = base.host { hosts.insert(host.lowercased()) }
        return PortalEndpoints(
            probeURL: base.appendingPathComponent("generate_204"),
            portalBase: base,
            vitHosts: hosts
        )
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func mockPortalBase(in arguments: [String]) -> URL? {
        #if DEBUG
        guard let flag = arguments.firstIndex(of: "-MatchPortalBase"),
              arguments.indices.contains(flag + 1),
              let url = URL(string: arguments[flag + 1]),
              url.scheme == "http",
              let host = url.host,
              ["127.0.0.1", "localhost"].contains(host)
        else { return nil }
        return url
        #else
        return nil
        #endif
    }
}
