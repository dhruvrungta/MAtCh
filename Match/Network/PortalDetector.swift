import Foundation

enum ProbeResult: Equatable, Sendable {
    /// HTTP 204: the internet works.
    case online
    /// A 3xx whose `Location` host is a VIT portal host, or a 200 whose body references one.
    case vitPortal(location: URL?)
    /// Any other response that is not 204.
    case otherPortal(status: Int)
    /// The probe host could not be resolved.
    case dnsFailure
    /// Timeout, connection refused, and so on.
    case error(String)
}

/// Asks a known no-content endpoint whether a captive portal is in the way, and whose.
///
/// Credentials may only ever be sent after this returns `.vitPortal`.
struct PortalDetector: Sendable {
    static let requestTimeout: TimeInterval = 3

    let http: any HTTPClient
    let endpoints: PortalEndpoints

    /// Probes once, giving up after `overallTimeout` whatever the request is doing.
    func probe(overallTimeout: Duration) async -> ProbeResult {
        await fetch(endpoints.probeURL, label: "probe", overallTimeout: overallTimeout)
    }

    /// Asks the Wi-Fi gateway for its front page and reports whether it sends visitors
    /// to the VIT portal, as the hostel gateways do even for a signed-in device.
    ///
    /// This carries no credentials and only tells "online on campus" apart from
    /// "online somewhere else". It never decides whether credentials may be sent.
    func gatewayLeadsToVITPortal(_ gateway: String, overallTimeout: Duration) async -> Bool {
        let result = await fetch(endpoints.base(host: gateway), label: "gateway check", overallTimeout: overallTimeout)
        if case .vitPortal = result { return true }
        return false
    }

    private func fetch(_ url: URL, label: String, overallTimeout: Duration) async -> ProbeResult {
        await withTaskGroup(of: ProbeResult.self) { group in
            group.addTask { await fetchOnce(url, label: label) }
            group.addTask {
                try? await Task.sleep(for: overallTimeout)
                return .error(HTTPError.timedOut.message)
            }
            let first = await group.next() ?? .error(HTTPError.timedOut.message)
            group.cancelAll()
            return first
        }
    }

    private func fetchOnce(_ url: URL, label: String) async -> ProbeResult {
        let started = ContinuousClock.now
        let result: ProbeResult
        do {
            let request = HTTPRequest(url: url, timeout: Self.requestTimeout)
            let response = try await http.send(request)
            result = classify(response)
            let elapsed = String(format: "%.2f", (ContinuousClock.now - started).seconds)
            Log.network.debug("\(label): HTTP \(response.status) in \(elapsed) s")
        } catch {
            result = error == .dnsFailure ? .dnsFailure : .error(error.message)
            Log.network.debug("\(label) failed: \(error.message)")
        }
        return result
    }

    func classify(_ response: HTTPResponse) -> ProbeResult {
        switch response.status {
        case 204:
            return .online
        case 300...399:
            if let value = response.header("Location"),
               let location = URL(string: value.trimmingCharacters(in: .whitespaces)),
               endpoints.isVITHost(location.host) {
                return .vitPortal(location: location)
            }
            return .otherPortal(status: response.status)
        case 200:
            let body = response.bodyText.lowercased()
            if endpoints.vitHosts.contains(where: { body.contains($0) }) {
                return .vitPortal(location: nil)
            }
            return .otherPortal(status: 200)
        default:
            return .otherPortal(status: response.status)
        }
    }
}
