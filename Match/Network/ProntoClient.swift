import Foundation

/// Signs in to and out of the Pronto Networks portal.
///
/// The caller is responsible for the credential gate: `login` must only be called
/// straight after a probe returned `.vitPortal`.
struct ProntoClient: Sendable {
    enum LoginOutcome: Equatable, Sendable {
        case success
        case failure(FailureReason)
    }

    struct LogoutOutcome: Equatable, Sendable {
        var success: Bool
        var session: PortalSession?
    }

    static let loginPath = "/cgi-bin/authlogin"
    static let loginQuery = "URI=http://example.com"
    static let logoutPath = "/cgi-bin/authlogout"
    static let serviceName = "ProntoAuthentication"
    static let userAgent = "Mozilla/5.0 (Android)"
    static let loginTimeout: TimeInterval = 5
    static let logoutTimeout: TimeInterval = 3

    let http: any HTTPClient
    let endpoints: PortalEndpoints

    // MARK: Sign in

    /// Signs in, making at most one retry: against `gateway` if the portal's name
    /// could not be resolved, against the portal's name again after any other
    /// transport error or unexpected status, and never after the portal answered
    /// with a rejection.
    func login(userId: String, password: String, gateway: String?) async -> LoginOutcome {
        let first = await attemptLogin(userId: userId, password: password, host: nil)
        switch first {
        case .success, .rejected:
            return first.outcome
        case .dnsFailure:
            guard let gateway else { return first.outcome }
            Log.portal.debug("sign-in: name lookup failed, retrying against the gateway")
            return await attemptLogin(userId: userId, password: password, host: gateway).outcome
        case .unexpectedStatus, .transport:
            Log.portal.debug("sign-in: retrying once")
            return await attemptLogin(userId: userId, password: password, host: nil).outcome
        }
    }

    func loginURL(host: String?) -> URL {
        url(path: Self.loginPath, query: Self.loginQuery, host: host)
    }

    func logoutURL(host: String?) -> URL {
        url(path: Self.logoutPath, query: nil, host: host)
    }

    static func loginBody(userId: String, password: String) -> String {
        FormEncoding.body([
            (name: "userId", value: userId),
            (name: "password", value: password),
        ]) + "&serviceName=\(serviceName)"
    }

    private enum Attempt {
        case success
        case rejected(FailureReason)
        case unexpectedStatus(Int)
        case dnsFailure
        case transport(String)

        var outcome: LoginOutcome {
            switch self {
            case .success: .success
            case .rejected(let reason): .failure(reason)
            case .unexpectedStatus(let status): .failure(.httpStatus(status))
            case .dnsFailure: .failure(.dnsFailure)
            case .transport(let message): .failure(.network(message))
            }
        }
    }

    private func attemptLogin(userId: String, password: String, host: String?) async -> Attempt {
        let request = HTTPRequest(
            method: .post,
            url: loginURL(host: host),
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": Self.userAgent,
            ],
            body: Data(Self.loginBody(userId: userId, password: password).utf8),
            timeout: Self.loginTimeout
        )
        do {
            let response = try await http.send(request)
            Log.portal.debug("sign-in: HTTP \(response.status)")
            switch response.status {
            case 301, 302:
                return .success
            case 200:
                switch LoginResponseClassifier.classify(response.bodyText) {
                case .success: return .success
                case .rejected(let reason): return .rejected(reason)
                }
            default:
                return .unexpectedStatus(response.status)
            }
        } catch {
            Log.portal.error("sign-in failed: \(error.message)")
            return error == .dnsFailure ? .dnsFailure : .transport(error.message)
        }
    }

    // MARK: Sign out

    /// Signs out, retrying once against `gateway` if the portal's name could not be resolved.
    func logout(gateway: String?, now: Date = Date()) async -> LogoutOutcome {
        do {
            return try await attemptLogout(host: nil, now: now)
        } catch {
            if error == .dnsFailure, let gateway {
                Log.portal.debug("sign-out: name lookup failed, retrying against the gateway")
                if let outcome = try? await attemptLogout(host: gateway, now: now) {
                    return outcome
                }
            }
            Log.portal.error("sign-out failed: \(error.message)")
            return LogoutOutcome(success: false, session: nil)
        }
    }

    private func attemptLogout(host: String?, now: Date) async throws(HTTPError) -> LogoutOutcome {
        let request = HTTPRequest(url: logoutURL(host: host), timeout: Self.logoutTimeout)
        let response = try await http.send(request)
        Log.portal.debug("sign-out: HTTP \(response.status)")
        return LogoutOutcome(
            success: (200...399).contains(response.status),
            session: LogoutParser.parse(response.bodyText, logoutTime: now)
        )
    }

    private func url(path: String, query: String?, host: String?) -> URL {
        let base = endpoints.base(host: host)
        var text = base.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        text += path
        if let query { text += "?\(query)" }
        return URL(string: text) ?? base
    }
}
