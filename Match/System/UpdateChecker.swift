import Foundation

/// A version such as `1.2.0`. Missing parts count as zero, and a leading `v` is ignored.
struct SemanticVersion: Comparable, Equatable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int
    /// True for versions with a suffix such as `-beta`, which sort before the plain version.
    var isPrerelease: Bool

    init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let core = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let numbers = core.first else { return nil }
        let parts = numbers.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let value = Int(part) else {
                return nil
            }
            values.append(value)
        }
        while values.count < 3 { values.append(0) }
        major = values[0]
        minor = values[1]
        patch = values[2]
        isPrerelease = core.count > 1
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.isPrerelease && !rhs.isPrerelease
    }
}

/// The contents of `latest.json`.
struct ReleaseInfo: Decodable, Equatable, Sendable {
    var version: String
    var url: String
    var sha256: String
    var notes: String?
}

/// Where releases are published. The names come from the build configuration.
struct ReleaseSource: Equatable, Sendable {
    var owner: String
    var repository: String

    /// Read from the app's Info.plist, which takes them from `project.yml`.
    static var bundled: ReleaseSource? {
        let info = Bundle.main.infoDictionary
        guard let owner = info?["MatchGitHubOwner"] as? String, !owner.isEmpty,
              let repository = info?["MatchGitHubRepository"] as? String, !repository.isEmpty
        else { return nil }
        return ReleaseSource(owner: owner, repository: repository)
    }

    private var pagesBase: String { "https://\(owner).github.io/\(repository)" }

    var feedURL: URL { URL(string: "\(pagesBase)/latest.json")! }

    /// The line a user pastes into Terminal to install or update.
    var installCommand: String { "curl -fsSL \(pagesBase)/install.sh | bash" }

    /// The release's page on GitHub, but only if the download really is one of this
    /// project's own release files. Anything else is not offered as a link.
    func releasePage(for release: ReleaseInfo) -> URL? {
        guard let download = URL(string: release.url), download.scheme == "https", download.host == "github.com" else {
            return nil
        }
        let parts = download.path.split(separator: "/").map(String.init)
        // /<owner>/<repository>/releases/download/<tag>/<file>
        guard parts.count == 6, parts[0].caseInsensitiveCompare(owner) == .orderedSame,
              parts[1].caseInsensitiveCompare(repository) == .orderedSame,
              parts[2] == "releases", parts[3] == "download"
        else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repository)/releases/tag/\(parts[4])")
    }
}

/// Asks whether a newer version has been published. It only ever reads one small
/// file, sends nothing about the user, and never downloads or installs anything.
struct UpdateChecker: Sendable {
    enum Outcome: Equatable, Sendable {
        case upToDate
        case available(ReleaseInfo)
        case failed(String)
    }

    static let timeout: TimeInterval = 10
    /// At most one automatic check in this long.
    static let interval: TimeInterval = 24 * 60 * 60

    let http: any HTTPClient
    let source: ReleaseSource
    let currentVersion: String

    func check() async -> Outcome {
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: source.feedURL, timeout: Self.timeout))
        } catch {
            return .failed(error.message)
        }
        guard response.status == 200 else {
            return .failed("the update server answered HTTP \(response.status)")
        }
        guard let release = try? JSONDecoder().decode(ReleaseInfo.self, from: response.body),
              let latest = SemanticVersion(release.version),
              source.releasePage(for: release) != nil
        else {
            return .failed("the update information could not be read")
        }
        guard let current = SemanticVersion(currentVersion) else {
            return .failed("this copy of MAtCh has no readable version")
        }
        return latest > current ? .available(release) : .upToDate
    }

    /// Whether enough time has passed for another automatic check.
    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A last check in the future means the clock was changed; check again.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }
}
