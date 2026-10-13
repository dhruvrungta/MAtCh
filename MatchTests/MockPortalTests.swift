import Foundation
import Testing
@testable import Match

/// What the opt-in tests below are pointed at, read from the environment.
private enum TestTargets {
    static let mockBase: URL? = ProcessInfo.processInfo.environment["MATCH_MOCK_BASE"].flatMap(URL.init(string:))
    static let atsHosts: [String]? = ProcessInfo.processInfo.environment["MATCH_ATS_HOSTS"]?
        .split(separator: ",").map(String.init)
}

/// End-to-end tests over real HTTP against `tools/mock_portal.py`. They only run when
/// `MATCH_MOCK_BASE` is set (see `make test-mock`), because they need that server.
///
/// They run inside the sandboxed app with its real Info.plist, so they also prove
/// that App Transport Security lets these plain-HTTP requests through.
@Suite(.serialized, .enabled(if: TestTargets.mockBase != nil))
struct MockPortalTests {
    private let http = URLSessionHTTPClient()

    private var endpoints: PortalEndpoints {
        get throws { PortalEndpoints.mock(base: try #require(TestTargets.mockBase)) }
    }

    /// Sets the mock's behaviour through its control endpoints.
    private func configure(mode: String, login: String) async throws {
        let base = try #require(TestTargets.mockBase)
        for path in ["__mode/\(mode)", "__login/\(login)"] {
            let response = try await http.send(HTTPRequest(url: base.appendingPathComponent(path), timeout: 3))
            #expect(response.status == 200)
        }
    }

    private func makeEngine(sessions: RecordingSessions) throws -> MatchEngine {
        MatchEngine(
            detector: PortalDetector(http: http, endpoints: try endpoints),
            client: ProntoClient(http: http, endpoints: try endpoints),
            credentials: InMemoryCredentialStore(Credentials(userId: "25BIT0088", password: "mock p&ssword")),
            settings: InMemorySettings(),
            notifier: SilentNotifier(),
            sessions: sessions,
            timing: MatchEngine.Timing(settleDelay: .milliseconds(50))
        )
    }

    @Test func redirectsAreReportedNotFollowed() async throws {
        try await configure(mode: "captive", login: "ok")
        let result = await PortalDetector(http: http, endpoints: try endpoints).probe(overallTimeout: .seconds(4))
        // Had the redirect been followed, there would be no location to report.
        guard case .vitPortal(let location?) = result else {
            Issue.record("expected a redirect to the portal, got \(result)")
            return
        }
        #expect(location.path == "/portal")
    }

    @Test func fullCycle() async throws {
        try await configure(mode: "captive", login: "ok")
        let sessions = RecordingSessions()
        let engine = try makeEngine(sessions: sessions)

        await engine.handle(.wifiUp(interface: "en0", gateway: nil))
        #expect(await eventually(timeout: .seconds(15)) { await engine.state.isConnected })

        await engine.logout()
        #expect(await eventually(timeout: .seconds(15)) { await engine.state == .portalDetected })
        #expect(sessions.sessions.map(\.duration) == [3723])
        #expect(sessions.sessions.first?.uploadBytes == 1234)
        #expect(sessions.sessions.first?.downloadBytes == 5678)

        await engine.connectNow()
        #expect(await eventually(timeout: .seconds(15)) { await engine.state.isConnected })
        await engine.shutdown()
    }

    @Test(arguments: [
        ("bad", FailureReason.wrongCredentials),
        ("limit", .sessionLimit),
        ("expired", .accountExpired),
    ])
    func rejections(_ login: String, _ reason: FailureReason) async throws {
        try await configure(mode: "captive", login: login)
        let engine = try makeEngine(sessions: RecordingSessions())
        await engine.handle(.wifiUp(interface: "en0", gateway: nil))
        #expect(await eventually(timeout: .seconds(15)) { await engine.state == .failed(reason) })
        await engine.shutdown()
    }

    @Test func alreadyOnlineIsLeftAlone() async throws {
        try await configure(mode: "online", login: "ok")
        let engine = try makeEngine(sessions: RecordingSessions())
        await engine.handle(.wifiUp(interface: "en0", gateway: nil))
        #expect(await eventually(timeout: .seconds(15)) { await engine.state == .online(campus: false) })
        await engine.shutdown()
    }
}

/// Reports what App Transport Security does with plain HTTP to address literals.
/// Opt-in (`MATCH_ATS_HOSTS=host,host,...`) because it makes real connection attempts.
@Suite(.enabled(if: TestTargets.atsHosts != nil))
struct ATSTests {
    @Test func plainHTTPToAddressLiterals() async throws {
        let http = URLSessionHTTPClient()
        for host in try #require(TestTargets.atsHosts) {
            let url = try #require(URL(string: "http://\(host)/"))
            var outcome: String
            do {
                let response = try await http.send(HTTPRequest(url: url, timeout: 3))
                outcome = "allowed (HTTP \(response.status))"
            } catch {
                // -1022 is "App Transport Security requires a secure connection".
                outcome = error.message.contains("-1022") ? "BLOCKED by ATS" : "allowed (then: \(error.message))"
            }
            print("ATS-CHECK \(host): \(outcome)")
        }
    }
}
