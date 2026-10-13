import Foundation

struct HTTPRequest: Equatable, Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    var method: Method = .get
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    /// Seconds.
    var timeout: TimeInterval
}

struct HTTPResponse: Equatable, Sendable {
    var status: Int
    /// Header names are lowercased.
    var headers: [String: String] = [:]
    var body = Data()

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    var bodyText: String {
        String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
    }
}

enum HTTPError: Error, Equatable, Sendable {
    /// The host name could not be resolved.
    case dnsFailure
    case timedOut
    case other(String)

    var message: String {
        switch self {
        case .dnsFailure: "the host name could not be resolved"
        case .timedOut: "the request timed out"
        case .other(let text): text
        }
    }
}

/// The only way Match talks HTTP. Implementations must never follow redirects: a
/// redirect is itself the answer the portal detector and the sign-in are looking for.
protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse
}

final class URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// `protocolClasses` lets tests intercept requests.
    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw HTTPError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.other("the response was not HTTP")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name.lowercased()] = value
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

extension HTTPError {
    init(_ error: any Error) {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            self = .other(nsError.localizedDescription)
            return
        }
        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            self = .dnsFailure
        case NSURLErrorTimedOut:
            self = .timedOut
        default:
            self = .other("\(nsError.localizedDescription) (\(nsError.code))")
        }
    }
}

/// Hands every redirect back to the caller as a plain response.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
