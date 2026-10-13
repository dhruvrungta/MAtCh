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

/// Holds the one saved sign-in.
protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    /// Replaces whatever was saved before.
    func save(_ credentials: Credentials) throws
    func clear() throws
}

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case malformedItem

    var message: String {
        switch self {
        case .unexpectedStatus(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "\(text) (\(status))"
        case .malformedItem:
            return "the saved item could not be read"
        }
    }
}

/// Stores the credentials as a single generic password in the login keychain.
///
/// The data-protection keychain is not available without a provisioning profile, so
/// this uses the file-based keychain, where access is tied to the app's code signature.
struct KeychainStore: CredentialStore {
    static let defaultService = "\(AppIdentity.bundleID).credentials"

    let service: String

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    func load() throws -> Credentials? {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }

        guard let attributes = item as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { throw KeychainError.malformedItem }
        return Credentials(userId: account, password: password)
    }

    func save(_ credentials: Credentials) throws {
        try clear()
        var attributes = baseQuery
        attributes[kSecAttrAccount as String] = credentials.userId
        attributes[kSecAttrLabel as String] = "Match Wi-Fi sign-in"
        attributes[kSecValueData as String] = Data(credentials.password.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func clear() throws {
        // One call removes one or all matches depending on the keychain, so repeat
        // until nothing is left.
        for _ in 0..<16 {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status == errSecItemNotFound { return }
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
