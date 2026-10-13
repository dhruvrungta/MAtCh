import Foundation
import os
@testable import Match

extension PortalEndpoints {
    /// Endpoints on reserved test domains, so nothing can reach a real host by accident.
    static let test = PortalEndpoints(
        probeURL: URL(string: "http://probe.test/generate_204")!,
        portalBase: URL(string: "http://portal.test")!,
        vitHosts: ["portal.test"]
    )
}

extension HTTPResponse {
    static func html(_ status: Int = 200, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "text/html"], body: Data(body.utf8))
    }

    static func redirect(to location: String, status: Int = 302) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["location": location])
    }
}

/// Lets a test hold requests in flight and release them later.
actor Gate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { waiters.count }

    func close() { isOpen = false }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func pass() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Returns scripted results in order, and records what was asked.
final class ScriptedHTTPClient: HTTPClient, Sendable {
    private struct State {
        var script: [Result<HTTPResponse, HTTPError>]
        var requests: [HTTPRequest] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ script: [Result<HTTPResponse, HTTPError>]) {
        state = OSAllocatedUnfairLock(initialState: State(script: script))
    }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }

    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        let next = state.withLock { state -> Result<HTTPResponse, HTTPError> in
            state.requests.append(request)
            return state.script.isEmpty ? .failure(.other("script exhausted")) : state.script.removeFirst()
        }
        return try next.get()
    }
}

/// Never answers until cancelled.
struct HangingHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        try? await Task.sleep(for: .seconds(60))
        throw HTTPError.timedOut
    }
}

/// A pretend network: a probe endpoint and a portal that behave according to `mode`
/// and `login`, the way the real ones do.
final class FakePortal: HTTPClient, Sendable {
    enum Mode: Sendable {
        /// The VIT portal intercepts the probe.
        case captive
        case online
        /// Some other network's login page intercepts the probe.
        case foreignPortal
        case unreachable
        case dnsFailure
    }

    enum LoginBehaviour: Sendable {
        case accept
        /// The portal says yes but the internet never opens up.
        case acceptButStayCaptive
        case reject(String)
        case status(Int)
        case transportError
    }

    static let logoutPage = """
        <html><body><h3>You have successfully logged out</h3>
        <table><tr><td>Time Spent : 1 H : 2 M : 3 S</td></tr>
        <tr><td>Bytes Sent : 1234</td></tr><tr><td>Bytes Received : 5678</td></tr></table>
        </body></html>
        """

    private struct State {
        var mode: Mode = .captive
        var login: LoginBehaviour = .accept
        var campusGateways: Set<String> = []
        var requests: [HTTPRequest] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Close this to hold sign-in requests in flight.
    let loginGate = Gate()

    func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }
    /// Gateways whose front page sends visitors to the VIT portal, as campus ones do.
    func setCampusGateways(_ gateways: Set<String>) { state.withLock { $0.campusGateways = gateways } }
    func setLogin(_ login: LoginBehaviour) { state.withLock { $0.login = login } }

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    var probeCount: Int { requests.count { $0.url.path == "/generate_204" } }
    var postCount: Int { requests.count { $0.method == .post } }
    var logoutCount: Int { requests.count { $0.url.path == ProntoClient.logoutPath } }
    var loginRequests: [HTTPRequest] { requests.filter { $0.url.path == ProntoClient.loginPath } }
    /// Requests for a gateway's front page.
    var gatewayRequests: [HTTPRequest] { requests.filter { $0.url.path.isEmpty || $0.url.path == "/" } }

    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        let (mode, login, campusGateways) = state.withLock { state in
            state.requests.append(request)
            return (state.mode, state.login, state.campusGateways)
        }

        switch request.url.path {
        case "", "/":
            // A gateway's front page.
            if let host = request.url.host, campusGateways.contains(host) {
                return .redirect(to: "http://portal.test/redirect.html?URI=http://\(host)/")
            }
            return .html(200, "<html>Router settings</html>")

        case "/generate_204":
            switch mode {
            case .online: return HTTPResponse(status: 204)
            case .captive: return .redirect(to: "http://portal.test/portal")
            case .foreignPortal: return .redirect(to: "http://login.cafe.example/welcome")
            case .unreachable: throw HTTPError.other("unreachable")
            case .dnsFailure: throw HTTPError.dnsFailure
            }

        case ProntoClient.loginPath:
            await loginGate.pass()
            switch login {
            case .accept:
                setMode(.online)
                return .html(200, "<html>You have successfully logged in</html>")
            case .acceptButStayCaptive:
                return .html(200, "<html>You have successfully logged in</html>")
            case .reject(let body):
                return .html(200, body)
            case .status(let status):
                return .html(status, "error")
            case .transportError:
                throw HTTPError.other("connection reset")
            }

        case ProntoClient.logoutPath:
            setMode(.captive)
            return .html(200, Self.logoutPage)

        default:
            return .html(404, "not found")
        }
    }
}

final class InMemoryCredentialStore: CredentialStore, Sendable {
    private struct State {
        var credentials: Credentials?
        /// Stands in for macOS wanting the user's approval before the item can be read.
        var needsApproval = false
        var promptCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ credentials: Credentials?, needsApproval: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(credentials: credentials, needsApproval: needsApproval))
    }

    /// How many times a read was allowed to ask the user.
    var promptCount: Int { state.withLock { $0.promptCount } }

    func savedUserId() throws -> String? { state.withLock { $0.credentials?.userId } }

    func approvalNeeded() throws -> Bool { state.withLock { $0.credentials != nil && $0.needsApproval } }

    func load(allowPrompt: Bool) throws -> CredentialLookup {
        state.withLock { state in
            guard let credentials = state.credentials else { return .missing }
            if state.needsApproval {
                guard allowPrompt else { return .needsApproval }
                // The user is asked, and approves.
                state.promptCount += 1
                state.needsApproval = false
            }
            return .found(credentials)
        }
    }

    func save(_ credentials: Credentials) throws {
        state.withLock {
            $0.credentials = credentials
            $0.needsApproval = false
        }
    }

    func clear() throws {
        try state.withLock { state in
            // Like the Keychain: a build that has not been approved may not delete the item.
            if state.credentials != nil, state.needsApproval { throw KeychainError.needsApproval }
            state.credentials = nil
        }
    }
}

final class InMemoryApprovals: KeychainApprovalRecord, Sendable {
    private let build = OSAllocatedUnfairLock<String?>(initialState: nil)

    var keychainApprovedBuild: String? { build.withLock { $0 } }
    func setKeychainApprovedBuild(_ build: String?) { self.build.withLock { $0 = build } }
}

final class InMemorySettings: EngineSettings, Sendable {
    private struct State {
        var autoLogin: Bool
        var gateways: Set<String>
        var names: [String]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(autoLogin: Bool = true, gateways: Set<String> = [], campusNetworkNames: [String] = ["VIT"]) {
        state = OSAllocatedUnfairLock(
            initialState: State(autoLogin: autoLogin, gateways: gateways, names: campusNetworkNames)
        )
    }

    var campusNetworkNames: [String] { state.withLock { $0.names } }

    var autoLoginEnabled: Bool { state.withLock { $0.autoLogin } }
    func setAutoLoginEnabled(_ enabled: Bool) { state.withLock { $0.autoLogin = enabled } }
    var knownCampusGateways: Set<String> { state.withLock { $0.gateways } }
    func rememberCampusGateway(_ gateway: String) { state.withLock { _ = $0.gateways.insert(gateway) } }
}

final class RecordingNotifier: Notifying, Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [NotificationEvent]())

    var events: [NotificationEvent] { recorded.withLock { $0 } }

    func notify(_ event: NotificationEvent) async {
        recorded.withLock { $0.append(event) }
    }
}

final class RecordingSessions: SessionRecording, Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [PortalSession]())

    var sessions: [PortalSession] { recorded.withLock { $0 } }

    func record(_ session: PortalSession) async {
        recorded.withLock { $0.append(session) }
    }
}

/// A stand-in for the vault.
final class FakeVault: VaultAccess, Sendable {
    private struct State {
        var available: Bool
        var items: [String: Credentials] = [:]
        var loads = 0
        var failing = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(available: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(available: available))
    }

    /// How many times the secret itself was asked for.
    var loads: Int { state.withLock { $0.loads } }
    func item(_ service: String) -> Credentials? { state.withLock { $0.items[service] } }
    /// Makes every later request fail, as when the service has gone away.
    func startFailing() { state.withLock { $0.failing = true } }

    func isAvailable() -> Bool { state.withLock { $0.available } }

    func account(service: String) throws -> String? {
        try state.withLock { state in
            if state.failing { throw VaultClient.Failure.unavailable("gone") }
            return state.items[service]?.userId
        }
    }

    func load(service: String) throws -> Credentials? {
        try state.withLock { state in
            if state.failing { throw VaultClient.Failure.unavailable("gone") }
            state.loads += 1
            return state.items[service]
        }
    }

    func save(_ credentials: Credentials, service: String) throws {
        try state.withLock { state in
            if state.failing { throw VaultClient.Failure.unavailable("gone") }
            state.items[service] = credentials
        }
    }

    func clear(service: String) throws {
        try state.withLock { state in
            if state.failing { throw VaultClient.Failure.unavailable("gone") }
            state.items[service] = nil
        }
    }
}

/// Interface counters a test sets by hand.
final class FakeCounters: ByteCounting, Sendable {
    private let current = OSAllocatedUnfairLock<InterfaceByteCounts?>(initialState: nil)

    func set(received: UInt64, sent: UInt64) {
        current.withLock { $0 = InterfaceByteCounts(received: received, sent: sent) }
    }

    func setUnavailable() { current.withLock { $0 = nil } }

    func counts(for interface: String) -> InterfaceByteCounts? { current.withLock { $0 } }
}

/// Counters that move on by a fixed amount at every reading.
final class SteppingCounters: ByteCounting, Sendable {
    private let readings = OSAllocatedUnfairLock(initialState: UInt64(0))

    func counts(for interface: String) -> InterfaceByteCounts? {
        let reading = readings.withLock { value -> UInt64 in
            value += 1
            return value
        }
        return InterfaceByteCounts(received: reading * 1_800_000, sent: reading * 90_000)
    }
}

struct FixedNetworkName: NetworkNaming {
    let name: String?
    func currentNetworkName() -> String? { name }
}

/// Finds files in the test bundle.
final class Fixtures {
    static func html(_ name: String) throws -> String {
        let bundle = Bundle(for: Fixtures.self)
        guard let url = bundle.url(forResource: name, withExtension: "html") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
