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
/// answers read, exactly as `cloud/handlers/create.ts`, `urls.ts`, `parts.ts` and
/// `complete.ts` speak them. Four routes, which is all of them.
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

    /// `GET /uploads/{ref}/parts?uploadId=u` — the route that serves `confirmedProgress`.
    /// The uploadId is a query parameter and not a body, because the route is a GET.
    public static func parts(ref: String, uploadId: String) -> PlaneRequest {
        PlaneRequest(method: "GET", path: "/uploads/\(ref)/parts",
                     query: [Key.uploadId: uploadId], body: nil)
    }

    /// `POST /uploads/{ref}/complete {"uploadId":u}` — the route that serves `finalize`.
    public static func complete(ref: String, uploadId: String) -> PlaneRequest {
        PlaneRequest(method: "POST", path: "/uploads/\(ref)/complete", query: [:],
                     body: encode([Key.uploadId: uploadId]))
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

    /// `{"parts":[n,...]}` from the parts route — the part numbers the authority holds,
    /// as the set they are. `parts.ts` answers 400 for a missing uploadId, 401
    /// unauthenticated, and 500 when `ListParts` truncates its page; reading past one page
    /// is 4b's, so a truncated answer is a plane failing here and not a short list.
    ///
    /// A part number below 1, or one that is not an integer, is `unreadableAnswer` and
    /// never a filtered-out element. Filtering would drop an answer this transport cannot
    /// read and hand Core a set that looks whole, and it would exist only to keep
    /// `ChunkID`'s `ordinal >= 1` precondition from firing — which is the precondition
    /// saying the answer is unreadable.
    public static func heldParts(from response: PlaneResponse) throws -> Set<Int> {
        let fields = try object(in: response)
        guard let entries = fields[Key.parts] as? [Any] else {
            throw ControlPlaneError.unreadableAnswer(status: response.status)
        }
        return try Set(entries.map { entry in
            guard let part = entry as? Int, part >= 1 else {
                throw ControlPlaneError.unreadableAnswer(status: response.status)
            }
            return part
        })
    }

    /// The complete route answered `{"etag":...}`. The etag is not read: the device retains
    /// no ETag (ADR-0006 §4), and this asks only whether the object was created.
    ///
    /// One refusal is named before the status rule runs. A 400 whose body is
    /// `{"error":"incomplete upload"}` is the stand-in refusing a complete over parts it
    /// does not hold (spec §3.2), and the transport turns it into
    /// `TransportError.incompleteUpload`. Any other 400 — `complete.ts`'s missing
    /// uploadId, say — is the route's own refusal and stays `refused(400)`.
    public static func completed(from response: PlaneResponse) throws {
        if response.status == 400,
           let parsed = try? JSONSerialization.jsonObject(with: response.body),
           let fields = parsed as? [String: Any],
           fields[Key.error] as? String == Value.incompleteUpload {
            throw ControlPlaneError.incompleteUpload
        }
        _ = try object(in: response)
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
        static let error = "error"
    }

    private enum Value {
        /// The stand-in's body for a complete it refuses, emitted exactly so in commit 7.
        static let incompleteUpload = "incomplete upload"
    }
}
