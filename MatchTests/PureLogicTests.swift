import Foundation
import Testing
@testable import Match

@Suite struct RegistrationNumberTests {
    @Test(arguments: ["25BIT0088", "19BCE1234", "00AAA0000"])
    func acceptsValidNumbers(_ value: String) {
        #expect(RegistrationNumber.isValid(value))
    }

    @Test(arguments: [
        "", "25BIT008", "25BIT00888", "25bit0088", "2BIT00888", "25BI10088", "25BIT00A8",
        "25-BIT-0088", " 25BIT0088", "25BIT0088 ", "२५BIT0088",
    ])
    func rejectsInvalidNumbers(_ value: String) {
        #expect(!RegistrationNumber.isValid(value))
    }

    @Test func normalizeTrimsAndUppercases() {
        #expect(RegistrationNumber.normalize("  25bit0088\n") == "25BIT0088")
        #expect(RegistrationNumber.isValid(RegistrationNumber.normalize(" 25bit0088 ")))
    }

    @Test func normalizeKeepsPunctuation() {
        #expect(RegistrationNumber.normalize("25-bit-0088") == "25-BIT-0088")
    }
}

@Suite struct FormEncodingTests {
    /// Expected values are what Java's `URLEncoder.encode(value, "UTF-8")` produces.
    @Test(arguments: [
        ("plainPassword123", "plainPassword123"),
        ("a b", "a+b"),
        ("  ", "++"),
        ("p&ss=w+rd%", "p%26ss%3Dw%2Brd%25"),
        ("#@!/", "%23%40%21%2F"),
        (".-*_", ".-*_"),
        ("~'()", "%7E%27%28%29"),
        ("a+b c", "a%2Bb+c"),
        ("pässwörd", "p%C3%A4ssw%C3%B6rd"),
        ("पास", "%E0%A4%AA%E0%A4%BE%E0%A4%B8"),
        ("🔑", "%F0%9F%94%91"),
        ("line\nbreak", "line%0Abreak"),
        ("", ""),
    ])
    func matchesJavaURLEncoder(_ input: String, _ expected: String) {
        #expect(FormEncoding.encode(input) == expected)
    }

    @Test func loginBodyHasTheExactShape() {
        let body = ProntoClient.loginBody(userId: "25BIT0088", password: "p&ss w=rd")
        #expect(body == "userId=25BIT0088&password=p%26ss+w%3Drd&serviceName=ProntoAuthentication")
    }
}

@Suite struct LoginResponseClassifierTests {
    @Test(arguments: LoginResponseClassifier.errorTokens)
    func everyErrorTokenMeansFailure(_ token: String) {
        let verdict = LoginResponseClassifier.classify("<html><b>\(token)</b></html>")
        #expect(verdict != .success)
    }

    @Test(arguments: LoginResponseClassifier.successTokens)
    func everySuccessTokenMeansSuccess(_ token: String) {
        #expect(LoginResponseClassifier.classify("<html>\(token)</html>") == .success)
    }

    @Test func emptyBodyIsSuccess() {
        #expect(LoginResponseClassifier.classify("") == .success)
    }

    @Test func unrecognisedBodyIsSuccess() {
        #expect(LoginResponseClassifier.classify("<html><body>Please wait</body></html>") == .success)
    }

    @Test func errorWinsOverSuccess() {
        let body = "Welcome! You were not successfully logged in: invalid password. window.location"
        #expect(LoginResponseClassifier.classify(body) == .rejected(.wrongCredentials))
    }

    @Test func matchingIgnoresCase() {
        #expect(LoginResponseClassifier.classify("AUTHENTICATION FAILED") == .rejected(.wrongCredentials))
        #expect(LoginResponseClassifier.classify("ACCESS GRANTED") == .success)
    }

    @Test(arguments: [
        ("invalid", FailureReason.wrongCredentials),
        ("incorrect", .wrongCredentials),
        ("wrong password", .wrongCredentials),
        ("authentication failed", .wrongCredentials),
        ("user not found", .wrongCredentials),
        ("account expired", .accountExpired),
        ("session limit", .sessionLimit),
        ("max session", .sessionLimit),
        ("login failed", .unknown),
    ])
    func mapsTokensToReasons(_ token: String, _ reason: FailureReason) {
        #expect(LoginResponseClassifier.classify("Sorry: \(token).") == .rejected(reason))
    }

    @Test func wrongCredentialsTakesPriorityOverOtherReasons() {
        #expect(LoginResponseClassifier.classify("session limit; invalid user") == .rejected(.wrongCredentials))
    }

    @Test func classifiesTheFixturePages() throws {
        #expect(LoginResponseClassifier.classify(try Fixtures.html("login-success")) == .success)
        #expect(LoginResponseClassifier.classify(try Fixtures.html("login-wrong-password")) == .rejected(.wrongCredentials))
        #expect(LoginResponseClassifier.classify(try Fixtures.html("login-session-limit")) == .rejected(.sessionLimit))
    }
}

@Suite struct LogoutParserTests {
    let logoutTime = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesAFullPage() throws {
        let session = try #require(LogoutParser.parse(try Fixtures.html("logout"), logoutTime: logoutTime))
        #expect(session.duration == 3 * 3600 + 25 * 60 + 7)
        #expect(session.uploadBytes == 73_400_320)
        #expect(session.downloadBytes == 1_288_490_188)
        #expect(session.logoutTime == logoutTime)
        #expect(session.loginTime == logoutTime.addingTimeInterval(-12307))
    }

    @Test func missingByteCountsDefaultToZero() throws {
        let session = try #require(LogoutParser.parse("Time Spent : 0 H : 5 M : 9 S", logoutTime: logoutTime))
        #expect(session.duration == 309)
        #expect(session.uploadBytes == 0)
        #expect(session.downloadBytes == 0)
    }

    @Test func onlyOneByteCountPresent() throws {
        let html = "Time Spent : 1 H : 0 M : 0 S <br> Bytes Received : 42"
        let session = try #require(LogoutParser.parse(html, logoutTime: logoutTime))
        #expect(session.uploadBytes == 0)
        #expect(session.downloadBytes == 42)
    }

    @Test(arguments: ["", "<html>Logged out</html>", "Time Spent : 1 H : 2 M", "Bytes Sent : 10 Bytes Received : 20"])
    func returnsNilWithoutTheTimeSpentLine(_ html: String) {
        #expect(LogoutParser.parse(html, logoutTime: logoutTime) == nil)
    }

    @Test func toleratesExtraWhitespaceAndCase() throws {
        let html = "time   spent:1H:2M:3S\n\tBYTES\n SENT  :  7\nbytes  received:9"
        let session = try #require(LogoutParser.parse(html, logoutTime: logoutTime))
        #expect(session.duration == 3723)
        #expect(session.uploadBytes == 7)
        #expect(session.downloadBytes == 9)
    }

    @Test func loginTimeNeverPrecedesTheEpoch() throws {
        let early = Date(timeIntervalSince1970: 60)
        let session = try #require(LogoutParser.parse("Time Spent : 5 H : 0 M : 0 S", logoutTime: early))
        #expect(session.loginTime == Date(timeIntervalSince1970: 0))
        #expect(session.duration == 18000)
    }
}

@Suite struct PortalEndpointsTests {
    let mockArguments = ["Match", "-MatchPortalBase", "http://127.0.0.1:8765"]

    @Test func productionEndpointsAreTheRealOnes() {
        let endpoints = PortalEndpoints.production
        #expect(endpoints.probeURL.absoluteString == "http://clients3.google.com/generate_204")
        #expect(endpoints.portalBase.absoluteString == "http://phc.prontonetworks.com")
        #expect(endpoints.vitHosts == ["phc.prontonetworks.com", "136.233.9.110"])
    }

    @Test func releaseBuildsIgnoreTheOverride() {
        #expect(PortalEndpoints.resolve(arguments: mockArguments, isDebugBuild: false) == .production)
    }

    @Test func debugBuildsHonourTheOverride() {
        let endpoints = PortalEndpoints.resolve(arguments: mockArguments, isDebugBuild: true)
        #expect(endpoints.probeURL.absoluteString == "http://127.0.0.1:8765/generate_204")
        #expect(endpoints.portalBase.absoluteString == "http://127.0.0.1:8765")
        #expect(endpoints.isVITHost("127.0.0.1"))
        #expect(endpoints.isVITHost("phc.prontonetworks.com"))
    }

    @Test(arguments: [
        ["Match"],
        ["Match", "-MatchPortalBase"],
        ["Match", "-MatchPortalBase", "http://evil.example:8765"],
        ["Match", "-MatchPortalBase", "http://192.168.1.50:8765"],
        ["Match", "-MatchPortalBase", "https://127.0.0.1:8765"],
        ["Match", "-MatchPortalBase", "not a url"],
    ])
    func debugBuildsRejectAnythingButALocalMock(_ arguments: [String]) {
        #expect(PortalEndpoints.resolve(arguments: arguments, isDebugBuild: true) == .production)
    }

    @Test func gatewaySubstitutionKeepsSchemeAndPort() {
        #expect(PortalEndpoints.production.base(host: "10.10.0.1").absoluteString == "http://10.10.0.1")
        #expect(PortalEndpoints.production.base(host: nil).absoluteString == "http://phc.prontonetworks.com")
        let mock = PortalEndpoints.mock(base: URL(string: "http://127.0.0.1:8765")!)
        #expect(mock.base(host: "10.10.0.1").absoluteString == "http://10.10.0.1:8765")
    }
}

@Suite struct CredentialsTests {
    @Test func neverPrintsThePassword() {
        let credentials = Credentials(userId: "25BIT0088", password: "hunter2-secret")
        #expect(!"\(credentials)".contains("hunter2"))
        #expect(!String(describing: credentials).contains("hunter2"))
        #expect(!String(reflecting: credentials).contains("hunter2"))
        var dumped = ""
        dump(credentials, to: &dumped)
        #expect(!dumped.contains("hunter2"))
    }
}
