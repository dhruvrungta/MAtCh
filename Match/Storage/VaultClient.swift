import Foundation
import Security

/// Talks to the vault, the unchanging service inside the app that owns the saved
/// sign-in (see `Vault/Sources/main.swift` for why it exists).
///
/// Every call opens a connection, waits for the answer and closes it again. The
/// vault only answers a copy of Match signed with the project's certificate, so in
/// any other build these calls fail with `.unavailable`.
struct VaultClient: Sendable {
    enum Failure: Error, Equatable {
        /// The vault could not be reached, or would not talk to this build.
        case unavailable(String)
        /// The vault reached the Keychain and the Keychain said no.
        case status(OSStatus)
    }

    func version() throws -> Int {
        try call { vault, finish in
            vault.version { finish(.success($0)) }
        }
    }

    func load(service: String) throws -> Credentials? {
        try call { vault, finish in
            vault.load(service: service) { account, password, status in
                guard status == errSecSuccess else { return finish(.failure(.status(status))) }
                if let account, let password {
                    finish(.success(Credentials(userId: account, password: password)))
                } else {
                    finish(.success(nil))
                }
            }
        }
    }

    func save(_ credentials: Credentials, service: String) throws {
        try call { vault, finish in
            vault.save(service: service, account: credentials.userId, password: credentials.password) { status in
                finish(status == errSecSuccess ? .success(()) : .failure(.status(status)))
            }
        }
    }

    func clear(service: String) throws {
        try call { vault, finish in
            vault.clear(service: service) { status in
                finish(status == errSecSuccess ? .success(()) : .failure(.status(status)))
            }
        }
    }

    /// Runs one request and waits for its reply.
    private func call<Value: Sendable>(
        _ request: (any VaultProtocol, @escaping @Sendable (Result<Value, Failure>) -> Void) -> Void
    ) throws -> Value {
        let connection = NSXPCConnection(serviceName: VaultInfo.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: VaultProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let answer = Answer<Value>()
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
            answer.set(.failure(.unavailable(error.localizedDescription)))
        }
        guard let vault = proxy as? any VaultProtocol else {
            throw Failure.unavailable("the vault does not speak the expected protocol")
        }
        // The proxy is synchronous: this returns only once the reply or the error
        // handler has run.
        request(vault) { answer.set($0) }
        return try answer.get().get()
    }
}

/// Holds the one reply to a request.
private final class Answer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, VaultClient.Failure>?

    func set(_ newResult: Result<Value, VaultClient.Failure>) {
        lock.withLock {
            // The first answer wins; a late error after a reply changes nothing.
            if result == nil { result = newResult }
        }
    }

    func get() -> Result<Value, VaultClient.Failure> {
        lock.withLock { result } ?? .failure(.unavailable("the vault did not answer"))
    }
}
