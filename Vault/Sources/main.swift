import Foundation
import Security

// The vault: a small service inside Match.app that owns the saved Wi-Fi sign-in.
//
// macOS ties a Keychain item to the exact build of the program that saved it, and asks
// the user again whenever a different build wants it. Match changes with every update;
// this program does not. It is built and signed once and shipped unchanged, so to the
// Keychain it is always the same program, and updates to Match never trigger that
// question. Rebuilding or re-signing the vault throws that away: don't, unless the
// vault itself has to change.
//
// Only a copy of Match signed with the project's certificate may talk to it.

final class Vault: NSObject, VaultProtocol {
    static let version = 1

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(Self.version)
    }

    func load(service: String, reply: @escaping @Sendable (String?, String?, Int32) -> Void) {
        guard isAllowed(service) else { return reply(nil, nil, VaultInfo.refused) }

        var query = baseQuery(service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return reply(nil, nil, errSecSuccess) }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return reply(nil, nil, status == errSecSuccess ? errSecDecode : status) }
        reply(account, password, errSecSuccess)
    }

    func save(service: String, account: String, password: String, reply: @escaping @Sendable (Int32) -> Void) {
        guard isAllowed(service) else { return reply(VaultInfo.refused) }

        let cleared = removeAll(service)
        guard cleared == errSecSuccess else { return reply(cleared) }

        var attributes = baseQuery(service)
        attributes[kSecAttrAccount as String] = account
        attributes[kSecAttrLabel as String] = "Match Wi-Fi sign-in"
        attributes[kSecValueData as String] = Data(password.utf8)
        reply(SecItemAdd(attributes as CFDictionary, nil))
    }

    func clear(service: String, reply: @escaping @Sendable (Int32) -> Void) {
        guard isAllowed(service) else { return reply(VaultInfo.refused) }
        reply(removeAll(service))
    }

    private func isAllowed(_ service: String) -> Bool {
        service.hasPrefix(VaultInfo.allowedServicePrefix)
    }

    private func baseQuery(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private func removeAll(_ service: String) -> OSStatus {
        for _ in 0..<16 {
            let status = SecItemDelete(baseQuery(service) as CFDictionary)
            if status == errSecItemNotFound { return errSecSuccess }
            if status != errSecSuccess { return status }
        }
        return errSecSuccess
    }
}

final class Doorkeeper: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // macOS itself drops every message from a caller that does not meet this.
        connection.setCodeSigningRequirement(VaultPeer.requirement)
        connection.exportedInterface = NSXPCInterface(with: VaultProtocol.self)
        connection.exportedObject = Vault()
        connection.resume()
        return true
    }
}

let doorkeeper = Doorkeeper()
let listener = NSXPCListener.service()
listener.delegate = doorkeeper
listener.resume()
