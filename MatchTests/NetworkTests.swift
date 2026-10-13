import Foundation
import Testing
@testable import Match

@Suite struct PortalDetectorTests {
    /// Runs a probe through the real `URLSession` client against a stubbed response.
    private func probe(_ stub: StubURLProtocol.Stub) async -> ProbeResult {
        let host = StubURLProtocol.register(stub)
        let endpoints = PortalEndpoints(
            probeURL: URL(string: "http://\(host)/generate_204")!,
            portalBase: URL(string: "http://portal.test")!,
            vitHosts: ["portal.test", "136.233.9.110"]
        )
        let detector = PortalDetector(
            http: URLSessionHTTPClient(protocolClasses: [StubURLProtocol.self]),
            endpoints: endpoints
        )
        return await detector.probe(overallTimeout: .seconds(5))
    }

    @Test func noContentMeansOnline() async {
        #expect(await probe(.response(status: 204)) == .online)
    }

    @Test func redirectToAVITHostIsTheVITPortal() async {
        let location = "http://portal.test/cgi-bin/authlogin?URI=http://clients3.google.com/generate_204"
        let result = await probe(.response(status: 302, headers: ["Location": location]))
        #expect(result == .vitPortal(location: URL(string: location)))
    }

    @Test func redirectToTheVITAddressIsTheVITPortal() async {
        let result = await probe(.response(status: 307, headers: ["Location": "http://136.233.9.110/registration/Main.jsp"]))
        #expect(result == .vitPortal(location: URL(string: "http://136.233.9.110/registration/Main.jsp")))
    }

    @Test func redirectToAForeignHostIsAnotherPortal() async {
        let result = await probe(.response(status: 302, headers: ["Location": "http://login.cafe.example/"]))
        #expect(result == .otherPortal(status: 302))
    }

    @Test func redirectToALookalikeHostIsAnotherPortal() async {
        let result = await probe(.response(status: 302, headers: ["Location": "http://portal.test.evil.example/"]))
        #expect(result == .otherPortal(status: 302))
    }

    @Test func redirectWithoutALocationIsAnotherPortal() async {
        #expect(await probe(.response(status: 302)) == .otherPortal(status: 302))
    }

    @Test func pageLinkingToAVITHostIsTheVITPortal() async {
        let body = "<html><form action=\"http://PORTAL.test/cgi-bin/authlogin\"></form></html>"
        #expect(await probe(.response(status: 200, body: body)) == .vitPortal(location: nil))
    }

    @Test func unrelatedPageIsAnotherPortal() async {
        #expect(await probe(.response(status: 200, body: "<html>Hotel Wi-Fi</html>")) == .otherPortal(status: 200))
    }

    @Test func serverErrorIsAnotherPortal() async {
        #expect(await probe(.response(status: 503)) == .otherPortal(status: 503))
    }

    @Test func unresolvableHostIsADNSFailure() async {
        #expect(await probe(.failure(.cannotFindHost)) == .dnsFailure)
        #expect(await probe(.failure(.dnsLookupFailed)) == .dnsFailure)
    }

    @Test func timeoutIsAnError() async {
        guard case .error = await probe(.failure(.timedOut)) else {
            Issue.record("expected an error result")
            return
        }
    }

    @Test func connectionFailureIsAnError() async {
        guard case .error = await probe(.failure(.cannotConnectToHost)) else {
            Issue.record("expected an error result")
            return
        }
    }

    @Test func givesUpAfterTheOverallTimeout() async {
        let detector = PortalDetector(http: HangingHTTPClient(), endpoints: .test)
        let started = ContinuousClock.now
        let result = await detector.probe(overallTimeout: .milliseconds(100))
        #expect(result == .error(HTTPError.timedOut.message))
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

@Suite struct ProntoClientTests {
    private let rejection = "<html>Invalid userid or password</html>"

    private func client(_ http: ScriptedHTTPClient) -> ProntoClient {
        ProntoClient(http: http, endpoints: .production)
    }

    private func login(_ http: ScriptedHTTPClient, gateway: String? = "10.10.0.1") async -> ProntoClient.LoginOutcome {
        await client(http).login(userId: "25BIT0088", password: "p&ss word", gateway: gateway)
    }

    @Test func redirectIsSuccess() async {
        for status in [301, 302] {
            let http = ScriptedHTTPClient([.success(.redirect(to: "http://example.com", status: status))])
            #expect(await login(http) == .success)
            #expect(http.requests.count == 1)
        }
    }

    @Test func successPageIsSuccess() async {
        let http = ScriptedHTTPClient([.success(.html(200, "<html>You are successfully logged in</html>"))])
        #expect(await login(http) == .success)
        #expect(http.requests.count == 1)
    }

    @Test func sendsExactlyTheExpectedRequest() async throws {
        let http = ScriptedHTTPClient([.success(.redirect(to: "http://example.com"))])
        _ = await login(http)
        let request = try #require(http.requests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "http://phc.prontonetworks.com/cgi-bin/authlogin?URI=http://example.com")
        #expect(request.headers == [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "Mozilla/5.0 (Android)",
        ])
        #expect(request.body == Data("userId=25BIT0088&password=p%26ss+word&serviceName=ProntoAuthentication".utf8))
        #expect(request.timeout == 5)
    }

    @Test func rejectionIsNeverRetried() async {
        let http = ScriptedHTTPClient([.success(.html(200, rejection)), .success(.redirect(to: "http://example.com"))])
        #expect(await login(http) == .failure(.wrongCredentials))
        #expect(http.requests.count == 1)
    }

    @Test func unexpectedStatusIsRetriedOnceAgainstTheHostname() async {
        let http = ScriptedHTTPClient([.success(.html(500, "oops")), .success(.html(500, "oops")), .success(.redirect(to: "x"))])
        #expect(await login(http) == .failure(.httpStatus(500)))
        #expect(http.requests.count == 2)
        #expect(http.requests.allSatisfy { $0.url.host == "phc.prontonetworks.com" })
    }

    @Test func unexpectedStatusThenSuccess() async {
        let http = ScriptedHTTPClient([.success(.html(502, "oops")), .success(.redirect(to: "http://example.com"))])
        #expect(await login(http) == .success)
        #expect(http.requests.count == 2)
    }

    @Test func transportErrorIsRetriedOnceAgainstTheHostname() async {
        let http = ScriptedHTTPClient([.failure(.timedOut), .failure(.other("reset")), .success(.redirect(to: "x"))])
        #expect(await login(http) == .failure(.network("reset")))
        #expect(http.requests.count == 2)
        #expect(http.requests.allSatisfy { $0.url.host == "phc.prontonetworks.com" })
    }

    @Test func retryThatIsRejectedStopsThere() async {
        let http = ScriptedHTTPClient([.failure(.timedOut), .success(.html(200, rejection)), .success(.redirect(to: "x"))])
        #expect(await login(http) == .failure(.wrongCredentials))
        #expect(http.requests.count == 2)
    }

    @Test func dnsFailureRetriesAgainstTheGateway() async throws {
        let http = ScriptedHTTPClient([.failure(.dnsFailure), .success(.redirect(to: "http://example.com"))])
        #expect(await login(http) == .success)
        #expect(http.requests.count == 2)
        let retry = try #require(http.requests.last)
        #expect(retry.url.absoluteString == "http://10.10.0.1/cgi-bin/authlogin?URI=http://example.com")
        #expect(retry.method == .post)
        #expect(retry.body == http.requests.first?.body)
    }

    @Test func gatewayRetryIsTheOnlyRetry() async {
        let http = ScriptedHTTPClient([.failure(.dnsFailure), .failure(.timedOut), .success(.redirect(to: "x"))])
        #expect(await login(http) == .failure(.network(HTTPError.timedOut.message)))
        #expect(http.requests.count == 2)
    }

    @Test func dnsFailureWithoutAGatewayIsNotRetried() async {
        let http = ScriptedHTTPClient([.failure(.dnsFailure), .success(.redirect(to: "x"))])
        #expect(await login(http, gateway: nil) == .failure(.dnsFailure))
        #expect(http.requests.count == 1)
    }

    @Test func logoutParsesTheUsageFigures() async throws {
        let http = ScriptedHTTPClient([.success(.html(200, FakePortal.logoutPage))])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = await client(http).logout(gateway: "10.10.0.1", now: now)
        #expect(outcome.success)
        #expect(outcome.session == PortalSession(
            loginTime: now.addingTimeInterval(-3723), logoutTime: now, duration: 3723,
            uploadBytes: 1234, downloadBytes: 5678
        ))
        let request = try #require(http.requests.first)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "http://phc.prontonetworks.com/cgi-bin/authlogout")
        #expect(request.timeout == 3)
    }

    @Test func logoutReadsTheBodyOfAnErrorResponse() async {
        let http = ScriptedHTTPClient([.success(.html(500, FakePortal.logoutPage))])
        let outcome = await client(http).logout(gateway: nil)
        #expect(!outcome.success)
        #expect(outcome.session?.duration == 3723)
    }

    @Test func logoutRetriesAgainstTheGatewayOnDNSFailure() async {
        let http = ScriptedHTTPClient([.failure(.dnsFailure), .success(.html(200, "bye"))])
        let outcome = await client(http).logout(gateway: "10.10.0.1")
        #expect(outcome.success)
        #expect(outcome.session == nil)
        #expect(http.requests.last?.url.absoluteString == "http://10.10.0.1/cgi-bin/authlogout")
    }

    @Test func logoutDoesNotRetryOtherFailures() async {
        let http = ScriptedHTTPClient([.failure(.timedOut), .success(.html(200, "bye"))])
        let outcome = await client(http).logout(gateway: "10.10.0.1")
        #expect(!outcome.success)
        #expect(http.requests.count == 1)
    }
}

@Suite struct URLSessionHTTPClientTests {
    @Test func putsTheRequestOnTheWireAsGiven() async throws {
        let host = StubURLProtocol.register(.response(status: 200, headers: ["X-Reply": "yes"], body: "hello"))
        let http = URLSessionHTTPClient(protocolClasses: [StubURLProtocol.self])
        let endpoints = PortalEndpoints(
            probeURL: URL(string: "http://\(host)/generate_204")!,
            portalBase: URL(string: "http://\(host)")!,
            vitHosts: [host]
        )
        let outcome = await ProntoClient(http: http, endpoints: endpoints)
            .login(userId: "25BIT0088", password: "pä ss&", gateway: nil)
        #expect(outcome == .success)

        let seen = try #require(StubURLProtocol.requests(to: host).first)
        #expect(seen.method == "POST")
        #expect(seen.url.absoluteString == "http://\(host)/cgi-bin/authlogin?URI=http://example.com")
        #expect(seen.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(seen.headers["User-Agent"] == "Mozilla/5.0 (Android)")
        #expect(seen.headers["Cookie"] == nil)
        #expect(String(decoding: seen.body, as: UTF8.self)
            == "userId=25BIT0088&password=p%C3%A4+ss%26&serviceName=ProntoAuthentication")
    }

    @Test func returnsStatusHeadersAndBody() async throws {
        let host = StubURLProtocol.register(.response(status: 418, headers: ["X-Reply": "yes"], body: "hello"))
        let http = URLSessionHTTPClient(protocolClasses: [StubURLProtocol.self])
        let response = try await http.send(HTTPRequest(url: URL(string: "http://\(host)/")!, timeout: 2))
        #expect(response.status == 418)
        #expect(response.header("x-reply") == "yes")
        #expect(response.bodyText == "hello")
    }

    @Test func mapsResolutionAndTimeoutErrors() async {
        let http = URLSessionHTTPClient(protocolClasses: [StubURLProtocol.self])
        func error(for code: URLError.Code) async -> HTTPError? {
            let host = StubURLProtocol.register(.failure(code))
            do {
                _ = try await http.send(HTTPRequest(url: URL(string: "http://\(host)/")!, timeout: 2))
                return nil
            } catch {
                return error
            }
        }
        #expect(await error(for: .cannotFindHost) == .dnsFailure)
        #expect(await error(for: .dnsLookupFailed) == .dnsFailure)
        #expect(await error(for: .timedOut) == .timedOut)
        guard case .other = await error(for: .networkConnectionLost) else {
            Issue.record("expected a generic error")
            return
        }
    }
}

@Suite struct KeychainStoreTests {
    private func makeStore(
        service: String = "\(AppIdentity.bundleID).tests.\(UUID().uuidString)",
        build: String = BuildIdentity.current,
        approvals: InMemoryApprovals = InMemoryApprovals()
    ) -> KeychainStore {
        KeychainStore(service: service, build: build, approvals: approvals)
    }

    @Test func savesLoadsReplacesAndClears() throws {
        let store = makeStore()
        defer { try? store.clear() }

        #expect(try store.savedUserId() == nil)
        #expect(try store.load(allowPrompt: false) == .missing)

        try store.save(Credentials(userId: "25BIT0088", password: "first pässword"))
        #expect(try store.savedUserId() == "25BIT0088")
        #expect(try store.load(allowPrompt: false) == .found(Credentials(userId: "25BIT0088", password: "first pässword")))

        // Saving again, even under another account, leaves exactly one item.
        try store.save(Credentials(userId: "24BCE1234", password: "second"))
        #expect(try store.load(allowPrompt: false) == .found(Credentials(userId: "24BCE1234", password: "second")))

        try store.clear()
        #expect(try store.savedUserId() == nil)
        #expect(try store.load(allowPrompt: false) == .missing)

        // Clearing when there is nothing to clear is not an error.
        try store.clear()
    }

    @Test func storesAreSeparatedByService() throws {
        let first = makeStore()
        let second = makeStore()
        defer {
            try? first.clear()
            try? second.clear()
        }
        try first.save(Credentials(userId: "25BIT0088", password: "one"))
        #expect(try second.load(allowPrompt: false) == .missing)
    }

    @Test func aBuildThatWasNotApprovedIsToldToAskWithoutTouchingTheSecret() throws {
        let service = "\(AppIdentity.bundleID).tests.\(UUID().uuidString)"
        let approvals = InMemoryApprovals()
        let saver = makeStore(service: service, approvals: approvals)
        defer { try? saver.clear() }
        try saver.save(Credentials(userId: "25BIT0088", password: "pw"))
        #expect(approvals.keychainApprovedBuild == BuildIdentity.current)

        // The same item, seen by what claims to be a different build.
        let updated = makeStore(service: service, build: "a-newer-build", approvals: approvals)
        #expect(try updated.savedUserId() == "25BIT0088")
        #expect(try updated.approvalNeeded())
        #expect(try !saver.approvalNeeded())
        #expect(try updated.load(allowPrompt: false) == .needsApproval)
        #expect(approvals.keychainApprovedBuild == BuildIdentity.current)

        // Once the user has been asked and the read succeeds, that build is remembered.
        #expect(try updated.load(allowPrompt: true) == .found(Credentials(userId: "25BIT0088", password: "pw")))
        #expect(approvals.keychainApprovedBuild == "a-newer-build")
        #expect(try !updated.approvalNeeded())
        #expect(try updated.load(allowPrompt: false) == .found(Credentials(userId: "25BIT0088", password: "pw")))
    }

    @Test func nothingSavedIsMissingEvenForAnUnapprovedBuild() throws {
        let store = makeStore(build: "a-newer-build")
        #expect(try !store.approvalNeeded())
        #expect(try store.load(allowPrompt: false) == .missing)
    }

    @Test func theBuildIdentityIsACodeHash() {
        #expect(BuildIdentity.current.count == 40)
        let isHex = BuildIdentity.current.allSatisfy { $0.isHexDigit }
        #expect(isHex)
    }
}

@Suite struct SettingsStoreTests {
    private func makeStore() throws -> (SettingsStore, UserDefaults, String) {
        let suite = "\(AppIdentity.bundleID).tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SettingsStore(defaults: defaults), defaults, suite)
    }

    @Test func autoLoginDefaultsToOnAndPersists() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.autoLoginEnabled)
        store.setAutoLoginEnabled(false)
        #expect(!SettingsStore(defaults: defaults).autoLoginEnabled)
    }

    @Test func remembersABoundedSetOfGateways() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.knownCampusGateways.isEmpty)

        store.rememberCampusGateway("10.0.0.1")
        store.rememberCampusGateway("10.0.0.1")
        #expect(store.knownCampusGateways == ["10.0.0.1"])

        for index in 0..<40 {
            store.rememberCampusGateway("172.16.0.\(index)")
        }
        #expect(store.knownCampusGateways.count == SettingsStore.maxRememberedGateways)
        #expect(store.knownCampusGateways.contains("172.16.0.39"))
        #expect(!store.knownCampusGateways.contains("10.0.0.1"))
    }
}
