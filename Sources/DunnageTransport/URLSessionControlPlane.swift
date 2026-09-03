import Foundation

/// The control plane, over a foreground `URLSession`: a `PlaneRequest` in, a
/// `PlaneResponse` out, and nothing read from either.
///
/// A foreground session and not the background one, because a background session runs
/// only upload and download tasks from files (spec §5.1) and the four routes are JSON.
/// Only the part PUTs go over the background session.
///
/// **The base URL and the bearer token are added here and nowhere else.** `PlaneRequest`
/// carries neither, which is what lets a test assert a whole request built by
/// `ControlPlaneWire` without a host or a credential in it.
///
/// **What is established where.** Nothing in this file is tier 1: it needs a socket.
///
/// - tier 1 (`swift test`, task 5's tests, unchanged): the request's method, path, query
///   and body, and every status and body reading. All of it is `ControlPlaneWire`'s and
///   none of it is this file's.
/// - simulator evidence (ADR-0007 §2, tier 2): that a request built this way reaches the
///   stand-in and its answer comes back, and that the bearer header is accepted as the
///   stand-in's `sub`.
/// - device harness (ADR-0007 §2, tier 3): nothing. This is a foreground session.
public struct URLSessionControlPlane: PlaneExchange {
    private let baseURL: URL
    private let bearerToken: String
    private let session: URLSession

    public init(baseURL: URL, bearerToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session
    }

    /// Carry the request and bring the answer back.
    ///
    /// A body this type cannot read is not this type's problem: it returns the status and
    /// the bytes whatever they are, and `ControlPlaneWire` decides what a 2xx with the
    /// wrong shape means. The one answer it cannot pass on is one that is not an
    /// `HTTPURLResponse`, because then there is no status to report; that is the only
    /// error this type invents about an answer.
    ///
    /// Nothing here is logged, and the errors thrown carry no header, no URL and no body.
    /// An error that quotes the request is an error that quotes the bearer token, and a
    /// token in a log line or a crash report is a token that has left the device.
    public func perform(_ request: PlaneRequest) async throws -> PlaneResponse {
        var http = URLRequest(url: try address(of: request))
        http.httpMethod = request.method
        // An answer from a cache is not an answer from the authority. `/parts` is a GET
        // with no `Cache-Control` on it, and a heuristically cached body would be
        // confirmed progress nobody stated (ADR-0001 §3). This holds whatever session is
        // injected.
        http.cachePolicy = .reloadIgnoringLocalCacheData
        http.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if let body = request.body {
            http.httpBody = body
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, answer) = try await session.data(for: http)
        guard let answer = answer as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return PlaneResponse(status: answer.statusCode, body: data)
    }

    /// The base URL, the request's path appended, and its query as items sorted by name —
    /// sorted for the reason `ControlPlaneWire` sorts a body's keys: a request fully
    /// determined by its arguments is one a reader can compare. This file names no route
    /// and no field; the path and the query are the wire's.
    ///
    /// A base URL that cannot be read as components, or components that cannot be read
    /// back as a URL, is a base URL the app was configured with and not an answer the
    /// plane gave. It is `URLError(.badURL)` with nothing attached — no URL, no token.
    private func address(of request: PlaneRequest) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        // A base URL is the one value a person types, and one written with a trailing
        // slash would otherwise give `//uploads` — a path no route serves.
        components.path = components.path.hasSuffix("/")
            ? String(components.path.dropLast()) + request.path
            : components.path + request.path
        if !request.query.isEmpty {
            components.queryItems = request.query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}
