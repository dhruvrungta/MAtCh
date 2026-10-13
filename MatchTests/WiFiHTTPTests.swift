import Foundation
import Network
import os
import Testing
@testable import Match

@Suite struct HTTPRequestWriterTests {
    private func text(_ request: HTTPRequest) throws -> String {
        String(decoding: try #require(HTTPRequestWriter.bytes(for: request)), as: UTF8.self)
    }

    @Test func writesTheSignInExactly() throws {
        let body = Data("userId=25BIT0088&password=p%26ss+word&serviceName=ProntoAuthentication".utf8)
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "http://phc.prontonetworks.com/cgi-bin/authlogin?URI=http://example.com")!,
            headers: ["Content-Type": "application/x-www-form-urlencoded", "User-Agent": "Mozilla/5.0 (Android)"],
            body: body, timeout: 5
        )
        #expect(try text(request) == """
            POST /cgi-bin/authlogin?URI=http://example.com HTTP/1.1\r
            Host: phc.prontonetworks.com\r
            Content-Type: application/x-www-form-urlencoded\r
            User-Agent: Mozilla/5.0 (Android)\r
            Accept: */*\r
            Connection: close\r
            Content-Length: 70\r
            \r
            userId=25BIT0088&password=p%26ss+word&serviceName=ProntoAuthentication
            """)
    }

    @Test func writesTheProbe() throws {
        let request = HTTPRequest(url: URL(string: "http://clients3.google.com/generate_204")!, timeout: 3)
        #expect(try text(request) == """
            GET /generate_204 HTTP/1.1\r
            Host: clients3.google.com\r
            User-Agent: Mozilla/5.0 (Macintosh)\r
            Accept: */*\r
            Connection: close\r
            \r

            """)
    }

    @Test func anAddressWithNoPathAsksForTheFrontPage() throws {
        let request = HTTPRequest(url: URL(string: "http://172.17.104.1")!, timeout: 3)
        #expect(try text(request).hasPrefix("GET / HTTP/1.1\r\nHost: 172.17.104.1\r\n"))
    }

    @Test func anUnusualPortGoesInTheHostLine() throws {
        let request = HTTPRequest(url: URL(string: "http://127.0.0.1:8765/generate_204")!, timeout: 3)
        #expect(try text(request).contains("\r\nHost: 127.0.0.1:8765\r\n"))
    }

    @Test func aHeaderCannotSmuggleInAnotherLine() {
        let request = HTTPRequest(
            url: URL(string: "http://portal.test/")!,
            headers: ["X-Note": "fine\r\nX-Injected: yes"], timeout: 3
        )
        #expect(HTTPRequestWriter.bytes(for: request) == nil)
    }
}

@Suite struct HTTPResponseParserTests {
    private func parse(_ text: String, endOfStream: Bool = false) -> HTTPResponseParser.Outcome {
        HTTPResponseParser.parse(Data(text.utf8), endOfStream: endOfStream)
    }

    private func response(_ outcome: HTTPResponseParser.Outcome) throws -> HTTPResponse {
        guard case .complete(let response) = outcome else {
            Issue.record("expected a complete response, got \(outcome)")
            throw CancellationError()
        }
        return response
    }

    @Test func noContent() throws {
        let parsed = try response(parse("HTTP/1.1 204 No Content\r\nDate: today\r\n\r\n"))
        #expect(parsed.status == 204)
        #expect(parsed.body.isEmpty)
    }

    @Test func aRedirectKeepsItsLocation() throws {
        let location = "http://phc.prontonetworks.com/redirect.html?URI=http://clients3.google.com/generate_204"
        let parsed = try response(parse("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\n\r\n"))
        #expect(parsed.status == 302)
        #expect(parsed.header("Location") == location)
        #expect(parsed.header("location") == location)
    }

    @Test func aBodyWithALength() throws {
        let parsed = try response(parse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloEXTRA"))
        #expect(parsed.bodyText == "hello")
    }

    @Test func aBodyStillArrivingIsNotFinished() {
        #expect(parse("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\npartial") == .incomplete)
        #expect(parse("HTTP/1.1 200 OK\r\nContent-Len") == .incomplete)
        #expect(parse("") == .incomplete)
    }

    @Test func aBodyWithNoLengthRunsToTheEndOfTheConnection() throws {
        let text = "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n<html>You are successfully logged in</html>"
        #expect(parse(text) == .incomplete)
        #expect(try response(parse(text, endOfStream: true)).bodyText == "<html>You are successfully logged in</html>")
    }

    @Test func aChunkedBody() throws {
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\n\r\n"
        #expect(try response(parse(text)).bodyText == "hello world")
    }

    @Test func aChunkedBodyStillArriving() throws {
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n wor"
        #expect(parse(text) == .incomplete)
        // If the server hangs up there, what arrived is kept.
        #expect(try response(parse(text, endOfStream: true)).bodyText == "hello wor")
    }

    @Test func aTruncatedBodyIsKeptWhenTheServerHangsUp() throws {
        let parsed = try response(parse("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\nTime Spent : 1 H", endOfStream: true))
        #expect(parsed.bodyText == "Time Spent : 1 H")
    }

    @Test func interimResponsesAreSkipped() throws {
        let parsed = try response(parse("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 302 Found\r\nLocation: http://example.com\r\nContent-Length: 0\r\n\r\n"))
        #expect(parsed.status == 302)
    }

    @Test func repeatedHeadersAreJoined() throws {
        let parsed = try response(parse("HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n"))
        #expect(parsed.header("Set-Cookie") == "a=1, b=2")
    }

    @Test(arguments: [
        "<html>not http at all</html>\r\n\r\n",
        "HTTP/1.1 OK\r\n\r\n",
        "HTTP/1.1 20 OK\r\n\r\n",
        "SSH-2.0-OpenSSH_9.6\r\n\r\n",
    ])
    func rubbishIsRejected(_ text: String) {
        guard case .invalid = parse(text, endOfStream: true) else {
            Issue.record("expected the response to be rejected")
            return
        }
    }

    @Test func aBadChunkSizeIsRejected() {
        guard case .invalid = parse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nhello\r\n") else {
            Issue.record("expected the response to be rejected")
            return
        }
    }

    @Test func aConnectionThatClosesBeforeTheHeadersEndIsAnError() {
        guard case .invalid = parse("HTTP/1.1 200 OK\r\nContent-Len", endOfStream: true) else {
            Issue.record("expected the response to be rejected")
            return
        }
    }
}

@Suite struct WiFiFirstHTTPClientTests {
    private struct FixedAttempt: InterfaceBoundHTTP {
        let result: Result<HTTPResponse, WiFiHTTPClient.Failure>
        func attempt(_ request: HTTPRequest) async -> Result<HTTPResponse, WiFiHTTPClient.Failure> { result }
    }

    private let request = HTTPRequest(
        method: .post, url: URL(string: "http://portal.test/cgi-bin/authlogin")!, body: Data("x".utf8), timeout: 5
    )

    @Test func aWiFiAnswerIsUsedAndNothingElseIsTried() async throws {
        let fallback = ScriptedHTTPClient([.success(HTTPResponse(status: 500))])
        let client = WiFiFirstHTTPClient(wifi: FixedAttempt(result: .success(HTTPResponse(status: 204))), fallback: fallback)
        #expect(try await client.send(request).status == 204)
        #expect(fallback.requests.isEmpty)
    }

    @Test func aRequestThatWasSentIsNeverSentAgainAnotherWay() async {
        // The sign-in went out over Wi-Fi and then the connection dropped. Sending it
        // again over another route could sign in twice.
        let fallback = ScriptedHTTPClient([.success(HTTPResponse(status: 204))])
        let failure = WiFiHTTPClient.Failure(error: .timedOut, requestWasSent: true)
        let client = WiFiFirstHTTPClient(wifi: FixedAttempt(result: .failure(failure)), fallback: fallback)
        await #expect(throws: HTTPError.timedOut) { try await client.send(request) }
        #expect(fallback.requests.isEmpty)
    }

    @Test func aConnectionThatWasNeverMadeFallsBack() async throws {
        let fallback = ScriptedHTTPClient([.success(HTTPResponse(status: 302))])
        let failure = WiFiHTTPClient.Failure(error: .other("no route"), requestWasSent: false)
        let client = WiFiFirstHTTPClient(wifi: FixedAttempt(result: .failure(failure)), fallback: fallback)
        #expect(try await client.send(request).status == 302)
        #expect(fallback.requests == [request])
    }

    @Test func theFallbacksOwnFailureIsReported() async {
        let fallback = ScriptedHTTPClient([.failure(.dnsFailure)])
        let failure = WiFiHTTPClient.Failure(error: .dnsFailure, requestWasSent: false)
        let client = WiFiFirstHTTPClient(wifi: FixedAttempt(result: .failure(failure)), fallback: fallback)
        await #expect(throws: HTTPError.dnsFailure) { try await client.send(request) }
    }

    @Test func somethingThatIsNotPlainHTTPIsRefusedBeforeConnecting() async {
        let client = WiFiHTTPClient()
        let secure = HTTPRequest(url: URL(string: "https://example.com/")!, timeout: 2)
        guard case .failure(let failure) = await client.attempt(secure) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(!failure.requestWasSent)
    }
}

/// The client's own networking, against `tools/mock_portal.py` on this machine. Not
/// tied to Wi-Fi here, since the mock is not on Wi-Fi. Runs with `make test-mock`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MATCH_MOCK_BASE"] != nil))
struct WiFiHTTPClientMockTests {
    private let client = WiFiHTTPClient(interfaceType: nil)

    private var base: URL {
        get throws { try #require(ProcessInfo.processInfo.environment["MATCH_MOCK_BASE"].flatMap(URL.init(string:))) }
    }

    private func get(_ path: String) async throws -> HTTPResponse {
        try await client.attempt(HTTPRequest(url: try base.appendingPathComponent(path), timeout: 3)).get()
    }

    @Test func readsARedirectWithoutFollowingIt() async throws {
        _ = try await get("__mode/captive")
        let response = try await get("generate_204")
        #expect(response.status == 302)
        #expect(response.header("Location")?.hasSuffix("/portal") == true)
    }

    @Test func readsNoContent() async throws {
        _ = try await get("__mode/online")
        #expect(try await get("generate_204").status == 204)
    }

    @Test func signsInAndOutThroughTheRealClients() async throws {
        _ = try await get("__mode/captive")
        _ = try await get("__login/ok")
        let endpoints = PortalEndpoints.mock(base: try base)
        let http = WiFiFirstHTTPClient(wifi: client, fallback: ScriptedHTTPClient([]))
        let pronto = ProntoClient(http: http, endpoints: endpoints)

        #expect(await PortalDetector(http: http, endpoints: endpoints).probe(overallTimeout: .seconds(4))
            == .vitPortal(location: try base.appendingPathComponent("portal")))
        #expect(await pronto.login(userId: "25BIT0088", password: "mock p&ss wörd", gateway: nil) == .success)
        #expect(await PortalDetector(http: http, endpoints: endpoints).probe(overallTimeout: .seconds(4)) == .online)
        let logout = await pronto.logout(gateway: nil)
        #expect(logout.success)
        #expect(logout.session?.duration == 3723)
    }

    @Test func aRejectedSignInIsReadCorrectly() async throws {
        _ = try await get("__mode/captive")
        _ = try await get("__login/bad")
        let http = WiFiFirstHTTPClient(wifi: client, fallback: ScriptedHTTPClient([]))
        let pronto = ProntoClient(http: http, endpoints: PortalEndpoints.mock(base: try base))
        #expect(await pronto.login(userId: "25BIT0088", password: "wrong", gateway: nil) == .failure(.wrongCredentials))
        _ = try await get("__login/ok")
    }

    @Test func nothingListeningIsAFailureBeforeSending() async {
        let request = HTTPRequest(url: URL(string: "http://127.0.0.1:9/")!, timeout: 3)
        guard case .failure(let failure) = await client.attempt(request) else {
            Issue.record("expected a failure")
            return
        }
        #expect(!failure.requestWasSent)
    }
}

/// What the Wi-Fi-bound client gets from real addresses. Opt-in
/// (`MATCH_WIFI_URLS=url,url,...`) because it makes real requests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MATCH_WIFI_URLS"] != nil))
struct WiFiHTTPClientLiveTests {
    @Test func overWiFi() async throws {
        let urls = try #require(ProcessInfo.processInfo.environment["MATCH_WIFI_URLS"]).split(separator: ",")
        let client = WiFiHTTPClient()
        for text in urls {
            let url = try #require(URL(string: String(text)))
            switch await client.attempt(HTTPRequest(url: url, timeout: 4)) {
            case .success(let response):
                print("WIFI-CHECK \(url.absoluteString): HTTP \(response.status) location=\(response.header("Location") ?? "-") bytes=\(response.body.count)")
            case .failure(let failure):
                print("WIFI-CHECK \(url.absoluteString): FAILED \(failure.error.message) sent=\(failure.requestWasSent)")
            }
        }
    }
}
