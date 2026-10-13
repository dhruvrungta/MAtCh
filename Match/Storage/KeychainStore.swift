import Foundation
import Security

struct Credentials: Equatable, Sendable {
    let userId: String
    let password: String
}

// Keeps the password out of anything that prints or interpolates a `Credentials`.
extension Credentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "Credentials(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

enum CredentialLookup: Equatable, Sendable {
    case found(Credentials)
    case missing
    /// A sign-in is saved, but macOS will ask the user before this build may read it.
    case needsApproval
}

/// Holds the one saved sign-in.
protocol CredentialStore: Sendable {
    /// The saved registration number. Never makes macOS ask the user anything.
    func savedUserId() throws -> String?
    /// Whether macOS would ask the user before this build may read the saved sign-in.
    /// Answers without touching the secret.
    func approvalNeeded() throws -> Bool
    /// Reads the saved sign-in. With `allowPrompt` false this returns `.needsApproval`
    /// rather than let macOS put up its approval dialog.
    func load(allowPrompt: Bool) throws -> CredentialLookup
    /// Replaces whatever was saved before.
    func save(_ credentials: Credentials) throws
    func clear() throws
}

/// Remembers which build the user last approved to read the Keychain item.
protocol KeychainApprovalRecord: Sendable {
    var keychainApprovedBuild: String? { get }
    func setKeychainApprovedBuild(_ build: String?)
}

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedItem
    /// macOS refuses to let this build change the item until the user has approved it.
    case needsApproval
    /// The vault stopped answering part-way through.
    case vaultUnavailable(String)

    var message: String {
        switch self {
        case .unexpectedStatus(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "\(text) (\(status))"
        case .malformedItem:
            return "the saved item could not be read"
        case .needsApproval:
            return "macOS needs you to approve Match first. Click Unlock and choose Always Allow."
        case .vaultUnavailable(let reason):
            return "Match's Keychain helper did not respond (\(reason)). Quit Match, open it again and retry."
        }
    }
}

/// Stores the credentials as a single generic password in the login keychain.
///
/// macOS ties access to the exact build that saved the item: any other build is
/// stopped by a system dialog until the user chooses Always Allow. To keep that
/// dialog from appearing unasked, this store remembers which build was last approved
/// and answers `.needsApproval` for any other, without touching the secret.
struct KeychainStore: CredentialStore {
    static let defaultService = "\(AppIdentity.bundleID).credentials"

    let service: String
    let build: String
    let approvals: any KeychainApprovalRecord

    init(
        service: String = KeychainStore.defaultService,
        build: String = BuildIdentity.current,
        approvals: any KeychainApprovalRecord
    ) {
        self.service = service
        self.build = build
        self.approvals = approvals
    }

    func savedUserId() throws -> String? {
        // Reading attributes alone needs no approval.
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let attributes = item as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String
        else { throw KeychainError.malformedItem }
        return account
    }

    func approvalNeeded() throws -> Bool {
        try savedUserId() != nil && approvals.keychainApprovedBuild != build
    }

    func load(allowPrompt: Bool) throws -> CredentialLookup {
        guard let userId = try savedUserId() else { return .missing }
        if !allowPrompt, approvals.keychainApprovedBuild != build {
            return .needsApproval
        }

        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedItem
            }
            approvals.setKeychainApprovedBuild(build)
            return .found(Credentials(userId: userId, password: password))
        case errSecItemNotFound:
            return .missing
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            // The user declined, or the dialog could not be shown.
            approvals.setKeychainApprovedBuild(nil)
            return .needsApproval
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func save(_ credentials: Credentials) throws {
        try clear()
        var attributes = baseQuery
        attributes[kSecAttrAccount as String] = credentials.userId
        attributes[kSecAttrLabel as String] = "Match Wi-Fi sign-in"
        attributes[kSecValueData as String] = Data(credentials.password.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        // The item now belongs to this build.
        approvals.setKeychainApprovedBuild(build)
    }

    func clear() throws {
        // One call removes one or all matches depending on the keychain, so repeat
        // until nothing is left.
        for _ in 0..<16 {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status == errSecItemNotFound { return }
            if status == errSecInvalidOwnerEdit { throw KeychainError.needsApproval }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }
}

/// Identifies the running build the way the Keychain does: by its code hash.
enum BuildIdentity {
    static let current: String = codeHash() ?? "unknown"

    private static func codeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
