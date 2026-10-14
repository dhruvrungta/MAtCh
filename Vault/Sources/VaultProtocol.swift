import Foundation

/// What Match asks of its vault, the small service that holds the saved sign-in.
///
/// This file is compiled into both the app and the vault, so the two always agree.
/// Every reply ends with a status: zero for success, otherwise a Keychain error code.
@objc protocol VaultProtocol {
    /// The vault's version, so the app can tell which one it is talking to.
    func version(reply: @escaping @Sendable (Int) -> Void)

    /// The saved sign-in, or nil values when there is none.
    func load(service: String, reply: @escaping @Sendable (_ account: String?, _ password: String?, _ status: Int32) -> Void)

    /// Replaces whatever was saved before.
    func save(service: String, account: String, password: String, reply: @escaping @Sendable (_ status: Int32) -> Void)

    func clear(service: String, reply: @escaping @Sendable (_ status: Int32) -> Void)
}

enum VaultInfo {
    /// The vault's bundle identifier, which is also the name the app connects to.
    static let serviceName = "com.dhruvrungta.match.vault"
    /// The vault refuses to touch Keychain items whose service does not start with this.
    static let allowedServicePrefix = "com.dhruvrungta.match.vault.credentials"
    /// A status of the vault's own, for a request it will not carry out.
    static let refused: Int32 = -1
}
