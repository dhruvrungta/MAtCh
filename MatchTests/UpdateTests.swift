import Foundation
import Testing
@testable import Match

@Suite struct SemanticVersionTests {
    @Test(arguments: [
        ("1.2.3", 1, 2, 3), ("v1.2.3", 1, 2, 3), ("0.1.0", 0, 1, 0), ("2", 2, 0, 0), ("2.5", 2, 5, 0),
        (" 1.0.0\n", 1, 0, 0), ("10.20.30", 10, 20, 30),
    ])
    func parses(_ text: String, _ major: Int, _ minor: Int, _ patch: Int) throws {
        let version = try #require(SemanticVersion(text))
        #expect(version.major == major)
        #expect(version.minor == minor)
        #expect(version.patch == patch)
        #expect(!version.isPrerelease)
    }

    @Test(arguments: ["", "v", "abc", "1.2.3.4", "1..2", "1.-2", "1.2.x", ".1", "1.", "१.२.३", "1 .2"])
    func rejects(_ text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test func ordersNumericallyNotAlphabetically() throws {
        func version(_ text: String) throws -> SemanticVersion { try #require(SemanticVersion(text)) }
        #expect(try version("1.10.0") > version("1.9.9"))
        #expect(try version("2.0.0") > version("1.99.99"))
        #expect(try version("1.0.1") > version("1.0.0"))
        #expect(try version("1.0") == version("1.0.0"))
        #expect(try version("v1.2.0") == version("1.2.0"))
        #expect(try !(version("1.2.0") > version("1.2.0")))
    }

    @Test func aPrereleaseComesBeforeItsRelease() throws {
        let beta = try #require(SemanticVersion("1.2.0-beta.1"))
        let release = try #require(SemanticVersion("1.2.0"))
        #expect(beta.isPrerelease)
        #expect(beta < release)
        #expect(try #require(SemanticVersion("1.1.9")) < beta)
    }
}

@Suite struct ReleaseSourceTests {
    let source = ReleaseSource(owner: "dhruvrungta", repository: "match")

    private func release(_ url: String) -> ReleaseInfo {
        ReleaseInfo(version: "1.2.0", url: url, sha256: "abc", notes: nil)
    }

    @Test func addressesAreBuiltFromTheRepositoryName() {
        #expect(source.feedURL.absoluteString == "https://dhruvrungta.github.io/match/latest.json")
        #expect(source.installCommand == "curl -fsSL https://dhruvrungta.github.io/match/install.sh | bash")
    }

    @Test func theReleasePageComesFromTheDownloadAddress() {
        let page = source.releasePage(for: release("https://github.com/dhruvrungta/match/releases/download/v1.2.0/Match-1.2.0.zip"))
        #expect(page?.absoluteString == "https://github.com/dhruvrungta/match/releases/tag/v1.2.0")
    }

    @Test(arguments: [
        "http://github.com/dhruvrungta/match/releases/download/v1.2.0/Match-1.2.0.zip",
        "https://github.com/someone-else/match/releases/download/v1.2.0/Match-1.2.0.zip",
        "https://github.com/dhruvrungta/other/releases/download/v1.2.0/Match-1.2.0.zip",
        "https://evil.example/dhruvrungta/match/releases/download/v1.2.0/Match-1.2.0.zip",
        "https://github.com.evil.example/dhruvrungta/match/releases/download/v1.2.0/Match-1.2.0.zip",
        "https://github.com/dhruvrungta/match/archive/v1.2.0.zip",
        "https://github.com/dhruvrungta/match/releases/download/v1.2.0/extra/Match-1.2.0.zip",
        "file:///Applications/Match.app",
        "not a url",
        "",
    ])
    func anythingElseIsNotOfferedAsALink(_ url: String) {
        #expect(source.releasePage(for: release(url)) == nil)
    }
}

@Suite struct UpdateCheckerTests {
    let source = ReleaseSource(owner: "dhruvrungta", repository: "match")

    private func feed(version: String, url: String? = nil) -> String {
        let url = url ?? "https://github.com/dhruvrungta/match/releases/download/v\(version)/Match-\(version).zip"
        return #"{"version": "\#(version)", "url": "\#(url)", "sha256": "0f3a", "notes": "Faster sign-in."}"#
    }

    private func check(
        current: String = "1.0.0", _ result: Result<HTTPResponse, HTTPError>
    ) async -> (UpdateChecker.Outcome, ScriptedHTTPClient) {
        let http = ScriptedHTTPClient([result])
        let checker = UpdateChecker(http: http, source: source, currentVersion: current)
        return (await checker.check(), http)
    }

    @Test func aNewerVersionIsReported() async {
        let (outcome, _) = await check(.success(.html(200, feed(version: "1.2.0"))))
        guard case .available(let release) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(release.version == "1.2.0")
        #expect(release.notes == "Faster sign-in.")
    }

    @Test func theSameOrAnOlderVersionIsUpToDate() async {
        #expect(await check(current: "1.2.0", .success(.html(200, feed(version: "1.2.0")))).0 == .upToDate)
        #expect(await check(current: "1.3.0", .success(.html(200, feed(version: "1.2.9")))).0 == .upToDate)
        #expect(await check(current: "1.10.0", .success(.html(200, feed(version: "1.9.0")))).0 == .upToDate)
    }

    @Test func asksOnlyForTheVersionFileAndSendsNothingElse() async throws {
        let (_, http) = await check(.success(.html(200, feed(version: "1.2.0"))))
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://dhruvrungta.github.io/match/latest.json")
        #expect(request.url.query == nil)
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
    }

    @Test func failuresAreReportedNotGuessed() async {
        func failed(_ result: Result<HTTPResponse, HTTPError>) async -> Bool {
            if case .failed = await check(result).0 { return true }
            return false
        }
        #expect(await failed(.failure(.timedOut)))
        #expect(await failed(.failure(.dnsFailure)))
        #expect(await failed(.success(.html(404, "Not Found"))))
        #expect(await failed(.success(.redirect(to: "https://elsewhere.example/latest.json"))))
        #expect(await failed(.success(.html(200, "<html>captive portal</html>"))))
        #expect(await failed(.success(.html(200, #"{"version": "soon", "url": "x", "sha256": "y"}"#))))
        #expect(await failed(.success(.html(200, #"{"version": "9.0.0"}"#))))
    }

    @Test func anUpdateHostedAnywhereElseIsNotOffered() async {
        let body = feed(version: "9.0.0", url: "https://evil.example/Match-9.0.0.zip")
        guard case .failed = await check(.success(.html(200, body))).0 else {
            Issue.record("a download from another site must not be offered")
            return
        }
    }

    @Test func automaticChecksHappenAtMostOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UpdateChecker.isDue(lastCheck: nil, now: now))
        #expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        // The clock was set back: don't wait for it to catch up.
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(7200), now: now))
    }
}

@Suite @MainActor struct UpdateFlowTests {
    private func makeAppState(feed: Result<HTTPResponse, HTTPError>, enabled: Bool = true) throws -> (AppState, ScriptedHTTPClient, SettingsStore) {
        let suite = "\(AppIdentity.bundleID).tests.\(UUID().uuidString)"
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: suite)))
        settings.setUpdateChecksEnabled(enabled)
        let store = InMemoryCredentialStore(nil)
        let portal = FakePortal()
        let sessions = SessionStore(fileURL: nil)
        let http = ScriptedHTTPClient([feed, feed])
        let engine = MatchEngine(
            detector: PortalDetector(http: portal, endpoints: .test),
            client: ProntoClient(http: portal, endpoints: .test),
            credentials: store, settings: settings, notifier: SilentNotifier(), sessions: sessions
        )
        let appState = AppState(
            engine: engine, credentials: store, settings: settings, sessions: sessions,
            usage: UsageMonitor(counters: FakeCounters(), interface: { "en0" }, sessions: sessions),
            networkNames: FixedNetworkName(name: nil),
            updateChecker: UpdateChecker(
                http: http, source: ReleaseSource(owner: "dhruvrungta", repository: "match"), currentVersion: "1.0.0"
            ),
            usingMockPortal: false
        )
        return (appState, http, settings)
    }

    private let newer = Result<HTTPResponse, HTTPError>.success(.html(200, """
        {"version": "1.2.0", "url": "https://github.com/dhruvrungta/match/releases/download/v1.2.0/Match-1.2.0.zip", "sha256": "0f3a"}
        """))

    @Test func anAutomaticCheckOffersTheUpdateAndIsNotRepeatedThatDay() async throws {
        let (appState, http, settings) = try makeAppState(feed: newer)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await appState.checkForUpdatesIfDue(now: now)
        #expect(appState.availableUpdate?.version == "1.2.0")
        #expect(appState.releasePage?.absoluteString == "https://github.com/dhruvrungta/match/releases/tag/v1.2.0")
        #expect(appState.updateCommand == "curl -fsSL https://dhruvrungta.github.io/match/install.sh | bash")
        #expect(settings.lastUpdateCheck == now)

        await appState.checkForUpdatesIfDue(now: now.addingTimeInterval(3600))
        #expect(http.requests.count == 1)
    }

    @Test func switchingChecksOffStopsAutomaticOnesOnly() async throws {
        let (appState, http, _) = try makeAppState(feed: newer, enabled: false)
        await appState.checkForUpdatesIfDue()
        #expect(http.requests.isEmpty)
        #expect(appState.availableUpdate == nil)

        // The user can still ask.
        await appState.checkForUpdates(askedByUser: true)
        #expect(http.requests.count == 1)
        #expect(appState.availableUpdate?.version == "1.2.0")
    }

    @Test func aFailedAutomaticCheckIsSilentButAManualOneSaysSo() async throws {
        let (appState, _, _) = try makeAppState(feed: .failure(.timedOut))
        await appState.checkForUpdatesIfDue()
        #expect(appState.updateCheckMessage == nil)
        #expect(appState.availableUpdate == nil)

        await appState.checkForUpdates(askedByUser: true)
        #expect(appState.updateCheckMessage == "Couldn't check for updates. Try again later.")
    }

    @Test func beingUpToDateIsOnlyAnnouncedWhenAsked() async throws {
        let same = Result<HTTPResponse, HTTPError>.success(.html(200, """
            {"version": "1.0.0", "url": "https://github.com/dhruvrungta/match/releases/download/v1.0.0/Match-1.0.0.zip", "sha256": "0f3a"}
            """))
        let (appState, _, _) = try makeAppState(feed: same)
        await appState.checkForUpdatesIfDue()
        #expect(appState.updateCheckMessage == nil)
        await appState.checkForUpdates(askedByUser: true)
        #expect(appState.updateCheckMessage == "MAtCh is up to date.")
        #expect(appState.availableUpdate == nil)
    }
}
