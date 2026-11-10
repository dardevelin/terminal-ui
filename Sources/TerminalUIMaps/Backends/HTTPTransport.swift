import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An HTTP GET a backend makes.
public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// What came back.
public struct HTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    public var body: [UInt8]

    public init(statusCode: Int, body: [UInt8]) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// How backends reach the network: injected, so tests answer from a stub
/// and make no network calls.
public protocol HTTPTransport: Sendable {
    func get(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// HTTP status codes a backend tells apart (RFC 9110 §15).
enum HTTPStatus {
    static let ok = 200
    static let noContent = 204
    static let notFound = 404
    static let successful = 200..<300
}

/// The transport over `URLSession`. The session's own handling applies:
/// it follows redirects, and inflates a `Content-Encoding: gzip` body before
/// handing it over (on Linux, as libcurl is asked to) — the vector tile
/// decoder takes the bytes either way.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// How long a request may wait for its server, the way a map wants it:
    /// short enough that a tile which will not come is given up on.
    public static let defaultTimeout: TimeInterval = 30

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: URLSessionTransport.defaultTimeout)
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw MapServiceError.invalidResponse("not an HTTP response")
        }
        return HTTPResponse(statusCode: http.statusCode, body: Array(data))
    }
}

/// Why a backend request failed.
public enum MapServiceError: Error, Sendable, Equatable {
    /// The server answered with a status that is not success.
    case httpStatus(Int, url: URL)
    /// The response could not be read as the service documents it.
    case invalidResponse(String)
    /// The router found no route between the places.
    case noRoute(String)
    /// The backend does not offer what was asked, such as a travel mode.
    case unsupported(String)
}

/// The header every request names its application in, as OpenStreetMap's
/// tile and Nominatim usage policies require an application to identify
/// itself (RFC 9110 §10.1.5).
enum MapUserAgent {
    static let headerField = "User-Agent"
}

extension HTTPTransport {
    /// A GET that succeeds with a 2xx body, or throws.
    func body(of request: HTTPRequest) async throws -> [UInt8] {
        let response = try await get(request)
        guard HTTPStatus.successful.contains(response.statusCode) else {
            throw MapServiceError.httpStatus(response.statusCode, url: request.url)
        }
        return response.body
    }

    /// A GET whose JSON body decodes as `type`.
    func json<Value: Decodable>(_ type: Value.Type, from request: HTTPRequest) async throws -> Value {
        let body = try await body(of: request)
        do {
            return try JSONDecoder().decode(type, from: Data(body))
        } catch {
            throw MapServiceError.invalidResponse("\(request.url.host() ?? "server"): \(error)")
        }
    }
}
