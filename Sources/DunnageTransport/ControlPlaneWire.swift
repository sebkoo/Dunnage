import Foundation

/// A part's presigned URL, beside the part number it is for. `part` n is `ChunkID(n)`:
/// the plane numbers parts the way Core numbers chunks, and the mapping is the identity.
public struct PartURL: Hashable, Sendable {
    public let part: Int
    public let url: URL

    public init(part: Int, url: URL) {
        self.part = part
        self.url = url
    }
}

/// The pure half of the control-plane boundary: the routes' requests built and their
/// answers read, exactly as `cloud/handlers/create.ts` and `urls.ts` speak them. Two
/// routes here; `parts` and `complete` arrive with the conformance.
///
/// Bodies are JSON with sorted keys, so a request is fully determined by its arguments
/// and a test can assert it whole. The bearer token and the base URL are the exchange's,
/// not the request's. A ref reaches a path unencoded because the plane's grammar
/// (`cloud/handlers/identity.ts`) admits nothing a path would have to escape.
public enum ControlPlaneWire {

    /// `POST /uploads {"parts":N,"ref":r}` — the route that serves `openSession`.
    public static func create(ref: String, parts: Int) -> PlaneRequest {
        PlaneRequest(method: "POST", path: "/uploads", query: [:],
                     body: encode([Key.parts: parts, Key.ref: ref]))
    }

    /// `POST /uploads/{ref}/urls {"parts":N,"uploadId":u}` — the route that serves
    /// `send`. `parts` is a count: the plane signs every part from 1 to N at once.
    public static func urls(ref: String, uploadId: String, parts: Int) -> PlaneRequest {
        PlaneRequest(method: "POST", path: "/uploads/\(ref)/urls", query: [:],
                     body: encode([Key.parts: parts, Key.uploadId: uploadId]))
    }

    /// `{"uploadId": ...}` from the create route.
    public static func uploadId(from response: PlaneResponse) throws -> String {
        let fields = try object(in: response)
        guard let uploadId = fields[Key.uploadId] as? String else {
            throw ControlPlaneError.unreadableAnswer(status: response.status)
        }
        return uploadId
    }

    /// `{"urls":[{"partNumber":n,"url":s}]}` from the urls route.
    public static func partURLs(from response: PlaneResponse) throws -> [PartURL] {
        let fields = try object(in: response)
        guard let entries = fields[Key.urls] as? [[String: Any]] else {
            throw ControlPlaneError.unreadableAnswer(status: response.status)
        }
        return try entries.map { entry in
            guard let part = entry[Key.partNumber] as? Int,
                  let string = entry[Key.url] as? String,
                  let url = URL(string: string)
            else { throw ControlPlaneError.unreadableAnswer(status: response.status) }
            return PartURL(part: part, url: url)
        }
    }

    /// The status rule, then the body. 400, 401 and 403 are the routes' documented
    /// refusals; 404 is the stand-in's reading of an upload the authority has no record
    /// of, provisional until 4b (ADR-0007 §9, item 2); anything else outside 2xx is the
    /// plane failing, not refusing, and the two are not one case for the reason Core
    /// keeps a refusal and an interruption apart. Only then is the body read.
    private static func object(in response: PlaneResponse) throws -> [String: Any] {
        switch response.status {
        case 400, 401, 403: throw ControlPlaneError.refused(status: response.status)
        case 404: throw ControlPlaneError.noSuchUpload
        case 200...299: break
        default: throw ControlPlaneError.unexpectedStatus(response.status)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: response.body),
              let fields = parsed as? [String: Any]
        else { throw ControlPlaneError.unreadableAnswer(status: response.status) }
        return fields
    }

    private static func encode(_ object: [String: Any]) -> Data {
        // Scalars under string keys: the serialiser cannot refuse this, and if it ever
        // did the request would be one no route should be asked with.
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private enum Key {
        static let parts = "parts"
        static let ref = "ref"
        static let uploadId = "uploadId"
        static let urls = "urls"
        static let partNumber = "partNumber"
        static let url = "url"
    }
}
