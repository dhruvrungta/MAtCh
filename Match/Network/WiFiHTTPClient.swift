import Foundation
import Network

/// Writes a request as HTTP/1.1 text.
enum HTTPRequestWriter {
    static let defaultUserAgent = "Mozilla/5.0 (Macintosh)"

    static func bytes(for request: HTTPRequest) -> Data? {
        guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty
        else { return nil }

        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            target += "?\(query)"
        }
        var hostHeader = host
        if let port = components.port, port != 80 {
            hostHeader += ":\(port)"
        }

        var lines = ["\(request.method.rawValue) \(target) HTTP/1.1", "Host: \(hostHeader)"]
        var headers = request.headers
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers["User-Agent"] = defaultUserAgent
        }
        for name in headers.keys.sorted() {
            // A line break inside a header would let its value start a new header.
            guard let value = headers[name], !"\(name)\(value)".contains(where: \.isNewline) else { return nil }
            lines.append("\(name): \(value)")
        }
        lines.append("Accept: */*")
        // One request per connection: a connection opened while a login page was in
        // the way stays intercepted, so none is ever reused.
        lines.append("Connection: close")
        if let body = request.body {
            lines.append("Content-Length: \(body.count)")
        }

        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body = request.body {
            data.append(body)
        }
        return data
    }
}

/// Reads an HTTP/1.1 response out of the bytes received so far.
enum HTTPResponseParser {
    enum Outcome: Equatable {
        /// More bytes are needed.
        case incomplete
        case complete(HTTPResponse)
        case invalid(String)
    }

    /// `endOfStream` says the server has closed the connection, so what is here is
    /// all there will be.
    static func parse(_ data: Data, endOfStream: Bool) -> Outcome {
        var remaining = data[...]
        // Interim responses (100 Continue and the like) come before the real one.
        for _ in 0..<5 {
            guard let headEnd = remaining.firstRange(of: Data("\r\n\r\n".utf8)) else {
                return endOfStream ? .invalid("the response ended before its headers did") : .incomplete
            }
            let head = String(decoding: remaining[..<headEnd.lowerBound], as: UTF8.self)
            let body = remaining[headEnd.upperBound...]

            var lines = head.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."),
                  statusLine[1].count == 3, let status = Int(statusLine[1])
            else { return .invalid("the response did not start with an HTTP status line") }

            if (100..<200).contains(status) {
                remaining = body
                continue
            }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = headers[name].map { "\($0), \(value)" } ?? value
            }

            if status == 204 || status == 304 {
                return .complete(HTTPResponse(status: status, headers: headers))
            }
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                switch decodeChunked(body) {
                case .finished(let decoded):
                    return .complete(HTTPResponse(status: status, headers: headers, body: decoded))
                case .partial(let decoded):
                    // A server that hangs up mid-body still told us most of what it had.
                    return endOfStream
                        ? .complete(HTTPResponse(status: status, headers: headers, body: decoded))
                        : .incomplete
                case .malformed:
                    return .invalid("the response's chunked body could not be read")
                }
            }
            if let length = headers["content-length"].flatMap({ Int($0) }), length >= 0 {
                if body.count >= length {
                    return .complete(HTTPResponse(status: status, headers: headers, body: Data(body.prefix(length))))
                }
                return endOfStream
                    ? .complete(HTTPResponse(status: status, headers: headers, body: Data(body)))
                    : .incomplete
            }
            // No length given: the body is everything up to the end of the connection.
            return endOfStream
                ? .complete(HTTPResponse(status: status, headers: headers, body: Data(body)))
                : .incomplete
        }
        return .invalid("too many interim responses")
    }

    private enum Chunked {
        case finished(Data)
        case partial(Data)
        case malformed
    }

    private static func decodeChunked(_ data: Data.SubSequence) -> Chunked {
        var decoded = Data()
        var rest = data
        let lineBreak = Data("\r\n".utf8)
        while true {
            guard let sizeEnd = rest.firstRange(of: lineBreak) else { return .partial(decoded) }
            let sizeText = String(decoding: rest[..<sizeEnd.lowerBound], as: UTF8.self)
                .split(separator: ";", maxSplits: 1)[safe: 0].map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .malformed }
            rest = rest[sizeEnd.upperBound...]
            if size == 0 { return .finished(decoded) }
            guard rest.count >= size else {
                decoded.append(rest)
                return .partial(decoded)
            }
            decoded.append(rest.prefix(size))
            rest = rest.dropFirst(size)
            guard rest.count >= 2 else { return .partial(decoded) }
            guard rest.prefix(2) == lineBreak else { return .malformed }
            rest = rest.dropFirst(2)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Something that sends a request over one particular kind of interface, and can say
/// whether a failed request had been sent.
protocol InterfaceBoundHTTP: Sendable {
    func attempt(_ request: HTTPRequest) async -> Result<HTTPResponse, WiFiHTTPClient.Failure>
}

/// A small HTTP client that sends its requests over the Wi-Fi interface, whatever
/// else the Mac is connected to.
///
/// macOS sends ordinary traffic over its preferred connection. On a Mac that is also
/// plugged into Ethernet that is not the Wi-Fi, so the probe would never meet the
/// Wi-Fi's login page; and while macOS is re-examining a network it can refuse
/// ordinary traffic altogether. Tying each connection to Wi-Fi avoids both.
///
/// It speaks plain HTTP/1.1 only, one request per connection, and never follows a
/// redirect, which is all the probe and the portal need.
struct WiFiHTTPClient: InterfaceBoundHTTP {
    /// Why a request failed, and whether any of it had been sent by then.
    struct Failure: Error, Equatable {
        var error: HTTPError
        /// False when the connection was never made, so nothing reached the server
        /// and the request can safely be tried another way.
        var requestWasSent: Bool
    }

    static let maximumResponseSize = 2 * 1024 * 1024

    /// The kind of interface every connection must use. `nil` leaves the choice to
    /// macOS, for tests that talk to a server on this machine.
    var interfaceType: NWInterface.InterfaceType? = .wifi

    func attempt(_ request: HTTPRequest) async -> Result<HTTPResponse, Failure> {
        guard request.url.scheme == "http", let host = request.url.host, !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(request.url.port ?? 80)),
              let bytes = HTTPRequestWriter.bytes(for: request)
        else {
            return .failure(Failure(error: .other("the address is not plain HTTP"), requestWasSent: false))
        }

        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        if let interfaceType {
            parameters.requiredInterfaceType = interfaceType
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let exchange = Exchange(connection: connection, request: bytes)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exchange.start(timeout: request.timeout) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            exchange.finish(.failure(Failure(error: .other("cancelled"), requestWasSent: true)))
        }
    }
}

/// One request and its response on one connection.
private final class Exchange: @unchecked Sendable {
    // Everything below is touched only on `queue`, apart from `finish`, which hops onto it.
    private let connection: NWConnection
    private let request: Data
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).wifi-http")
    private var received = Data()
    private var requestWasSent = false
    private var completion: ((Result<HTTPResponse, WiFiHTTPClient.Failure>) -> Void)?

    init(connection: NWConnection, request: Data) {
        self.connection = connection
        self.request = request
    }

    func start(timeout: TimeInterval, completion: @escaping (Result<HTTPResponse, WiFiHTTPClient.Failure>) -> Void) {
        queue.async {
            self.completion = completion
            // This keeps the exchange alive until `complete` clears the handler,
            // which the timeout guarantees will happen.
            self.connection.stateUpdateHandler = { state in
                self.connectionChanged(to: state)
            }
            self.connection.start(queue: self.queue)
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            complete(.failure(failure(.timedOut)))
        }
    }

    func finish(_ result: Result<HTTPResponse, WiFiHTTPClient.Failure>) {
        queue.async { self.complete(result) }
    }

    private func connectionChanged(to state: NWConnection.State) {
        switch state {
        case .ready:
            send()
        case .waiting(let error), .failed(let error):
            // "Waiting" means there is no usable route right now. The engine has its
            // own retries, so this does not wait for one to appear.
            complete(.failure(failure(HTTPError(error))))
        default:
            break
        }
    }

    private func send() {
        requestWasSent = true
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                complete(.failure(failure(HTTPError(error))))
            } else {
                receive()
            }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                received.append(data)
            }
            if received.count > WiFiHTTPClient.maximumResponseSize {
                return complete(.failure(failure(.other("the response was too large"))))
            }
            let endOfStream = isComplete || error != nil
            switch HTTPResponseParser.parse(received, endOfStream: endOfStream) {
            case .complete(let response):
                complete(.success(response))
            case .invalid(let reason):
                complete(.failure(failure(error.map(HTTPError.init) ?? .other(reason))))
            case .incomplete:
                receive()
            }
        }
    }

    private func failure(_ error: HTTPError) -> WiFiHTTPClient.Failure {
        WiFiHTTPClient.Failure(error: error, requestWasSent: requestWasSent)
    }

    private func complete(_ result: Result<HTTPResponse, WiFiHTTPClient.Failure>) {
        guard let completion else { return }
        self.completion = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(result)
    }
}

extension HTTPError {
    init(_ error: NWError) {
        switch error {
        case .dns:
            self = .dnsFailure
        case .posix(.ETIMEDOUT):
            self = .timedOut
        default:
            self = .other(error.localizedDescription)
        }
    }
}

/// Sends requests over Wi-Fi, and falls back to the system's ordinary networking only
/// when the Wi-Fi connection could not be made at all.
///
/// If any of the request was sent, the failure is final: sending it again another way
/// could deliver a sign-in twice.
struct WiFiFirstHTTPClient: HTTPClient {
    let wifi: any InterfaceBoundHTTP
    let fallback: any HTTPClient

    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        switch await wifi.attempt(request) {
        case .success(let response):
            return response
        case .failure(let failure) where failure.requestWasSent:
            throw failure.error
        case .failure(let failure):
            Log.network.debug("could not connect over Wi-Fi (\(failure.error.message)); using the default route")
            return try await fallback.send(request)
        }
    }
}
