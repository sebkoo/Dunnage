import Foundation

/// One request to the control plane, with no host and no token: the exchange adds both.
/// Fully determined by the arguments that built it, so a test can assert it whole.
public struct PlaneRequest: Hashable, Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: Data?

    public init(method: String, path: String, query: [String: String], body: Data?) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }
}

/// What the plane answered: a status and a body, and nothing read from either yet.
public struct PlaneResponse: Hashable, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The one boundary between this transport and the control plane: a request in, a
/// response out. Stateless — building the request and reading the answer are pure
/// functions in `ControlPlaneWire`, and the exchange carries bytes. The production
/// exchange (a later commit's) adds the base URL and the bearer token; the test target's
/// is a closure the test hands in, so the canned answers and the request journal are the
/// test's own and no shared double stands here.
public protocol PlaneExchange: Sendable {
    func perform(_ request: PlaneRequest) async throws -> PlaneResponse
}

/// What the plane's answer meant when it was not the route's answer. A refusal and a
/// failure are kept apart for the reason Core keeps a refusal and an interruption apart:
/// "the plane said no" and "the plane did not answer as a plane" are different facts,
/// and the driver treats both as thrown errors (ADR-0005 §8) while the name is what the
/// record keeps.
public enum ControlPlaneError: Error, Hashable, Sendable {
    /// One of the routes' documented refusals: 400, 401, 403.
    case refused(status: Int)
    /// Any other status outside 2xx. A 5xx is the plane failing, not refusing.
    case unexpectedStatus(Int)
    /// 404. Provisional: the stand-in's reading of an upload the authority has no record
    /// of, and what the plane renders for one is settled in 4b (ADR-0007 §9, item 2).
    case noSuchUpload
    /// A 2xx whose body is not the route's shape.
    case unreadableAnswer(status: Int)
    /// The complete route's own refusal: a 400 whose body is `{"error":"incomplete
    /// upload"}`. It is a `refused` the transport can name, and it is named here because
    /// the transport turns it into `TransportError.incompleteUpload` and the driver's
    /// caller is entitled to the difference between "the authority does not hold every
    /// part" and "the request was malformed". Only the complete route produces it.
    case incompleteUpload
}
