import Foundation
import os

/// Intercepts `URLSession` requests and answers them from a table keyed by host, so
/// tests running in parallel don't see each other's stubs.
final class StubURLProtocol: URLProtocol {
    enum Stub: Sendable {
        case response(status: Int, headers: [String: String] = [:], body: String = "")
        case failure(URLError.Code)
    }

    struct Seen: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    private static let stubs = OSAllocatedUnfairLock(initialState: [String: Stub]())
    private static let seen = OSAllocatedUnfairLock(initialState: [String: [Seen]]())

    /// Registers a stub and returns the unique host it answers for.
    static func register(_ stub: Stub) -> String {
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        stubs.withLock { $0[host] = stub }
        return host
    }

    static func requests(to host: String) -> [Seen] {
        seen.withLock { $0[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let record = Seen(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request)
        )
        Self.seen.withLock { $0[host, default: []].append(record) }

        switch Self.stubs.withLock({ $0[host] }) {
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    /// `URLSession` hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
