import Foundation

/// Decides whether the portal's `200` response to a sign-in means success.
///
/// Matching on text in the HTML is the only signal the portal gives, so these token
/// lists are deliberately not "improved": an explicit error token means failure, and
/// anything else counts as success.
enum LoginResponseClassifier {
    enum Verdict: Equatable, Sendable {
        case success
        case rejected(FailureReason)
    }

    static let wrongCredentialsTokens = [
        "invalid", "incorrect", "wrong password", "authentication failed", "user not found",
    ]
    static let accountExpiredTokens = ["account expired"]
    static let sessionLimitTokens = ["session limit", "max session"]
    static let otherErrorTokens = ["login failed"]

    static let successTokens = [
        "access granted", "successfully", "logged in", "already logged in", "welcome", "success",
        "http-equiv=\"refresh\"", "location.href", "window.location", "http://example.com",
    ]

    static var errorTokens: [String] {
        wrongCredentialsTokens + accountExpiredTokens + sessionLimitTokens + otherErrorTokens
    }

    static func classify(_ body: String) -> Verdict {
        let lowered = body.lowercased()
        func containsAny(_ tokens: [String]) -> Bool { tokens.contains { lowered.contains($0) } }

        let explicitError = containsAny(errorTokens)
        let successToken = containsAny(successTokens) || !explicitError
        if !explicitError && successToken { return .success }

        if containsAny(wrongCredentialsTokens) { return .rejected(.wrongCredentials) }
        if containsAny(accountExpiredTokens) { return .rejected(.accountExpired) }
        if containsAny(sessionLimitTokens) { return .rejected(.sessionLimit) }
        return .rejected(.unknown)
    }
}
