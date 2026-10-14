import Foundation
import Security

/// What the credential store needs from the vault.
protocol VaultAccess: Sendable {
    /// Whether the vault answers this build at all.
    func isAvailable() -> Bool
    /// The account name of the item saved under `service`, read without the vault and
    /// without macOS asking anything.
    func account(service: String) throws -> String?
    func load(service: String) throws -> Credentials?
    func save(_ credentials: Credentials, service: String) throws
    func clear(service: String) throws
}

extension VaultClient: VaultAccess {
    func isAvailable() -> Bool {
        (try? version()) != nil
    }

    func account(service: String) throws -> String? {
        // Reading an item's attributes needs nobody's approval, so the app does it itself.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        query[kSecReturnData as String] = false
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        return (item as? [String: Any])?[kSecAttrAccount as String] as? String
    }
}

/// Keeps the saved sign-in in the vault, so that updating Match never makes macOS ask
/// the user to approve Keychain access again.
///
/// Two older arrangements are still honoured:
/// - A sign-in saved by a version from before the vault (`legacy`) is moved into the
///   vault the first time it can be read. That one read may need the user's approval.
/// - A build the vault will not talk to (one not signed with the project's
///   certificate, such as a developer's ad-hoc build) uses `legacy` for everything.
struct VaultCredentialStore: CredentialStore {
    static let defaultService = VaultInfo.allowedServicePrefix

    let vault: any VaultAccess
    let service: String
    let legacy: any CredentialStore
    /// Decided once, when the store is made.
    let usesVault: Bool

    init(vault: any VaultAccess, service: String = VaultCredentialStore.defaultService, legacy: any CredentialStore) {
        self.vault = vault
        self.service = service
        self.legacy = legacy
        self.usesVault = vault.isAvailable()
        if !usesVault {
            Log.storage.debug("the vault is not available to this build; using the Keychain directly")
        }
    }

    func savedUserId() throws -> String? {
        guard usesVault else { return try legacy.savedUserId() }
        if let account = try translating({ try vault.account(service: service) }) {
            return account
        }
        return try legacy.savedUserId()
    }

    func approvalNeeded() throws -> Bool {
        guard usesVault else { return try legacy.approvalNeeded() }
        if try translating({ try vault.account(service: service) }) != nil {
            return false
        }
        // Only an older version's item, not yet moved into the vault, can need it.
        return try legacy.approvalNeeded()
    }

    func load(allowPrompt: Bool) throws -> CredentialLookup {
        guard usesVault else { return try legacy.load(allowPrompt: allowPrompt) }
        if let saved = try translating({ try vault.load(service: service) }) {
            return .found(saved)
        }

        let older = try legacy.load(allowPrompt: allowPrompt)
        guard case .found(let credentials) = older else { return older }
        // Move it into the vault. From now on no update will be asked about it.
        try translating { try vault.save(credentials, service: service) }
        Log.storage.debug("moved the saved sign-in into the vault")
        removeLegacyItem()
        return .found(credentials)
    }

    func save(_ credentials: Credentials) throws {
        guard usesVault else { return try legacy.save(credentials) }
        try translating { try vault.save(credentials, service: service) }
        removeLegacyItem()
    }

    func clear() throws {
        guard usesVault else { return try legacy.clear() }
        try translating { try vault.clear(service: service) }
        // An older version's item that macOS will not let this build delete is
        // reported, so the user knows something is left.
        try legacy.clear()
    }

    /// The older item is no longer used once the vault holds the sign-in. macOS may
    /// refuse to let this build delete it; that is harmless, so it is only logged.
    private func removeLegacyItem() {
        do {
            try legacy.clear()
        } catch {
            Log.storage.debug("an older saved sign-in could not be removed: \(String(describing: error))")
        }
    }

    private func translating<Value>(_ work: () throws -> Value) throws -> Value {
        do {
            return try work()
        } catch let failure as VaultClient.Failure {
            switch failure {
            case .status(let status): throw KeychainError.unexpectedStatus(status)
            case .unavailable(let reason): throw KeychainError.vaultUnavailable(reason)
            }
        }
    }
}
