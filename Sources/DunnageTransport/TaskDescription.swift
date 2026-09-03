import Foundation
import DunnageCore

/// What a background task is named after: one chunk of one upload, under one transport
/// operation.
///
/// The description is the one string the system persists with a task across relaunch
/// (ADR-0007 §4), so it is all a relaunched process has to say whose task it is. It is a
/// JSON object with sorted keys, in the ledger's own style:
///
///     {"chunk":3,"session":"<ref>/<uploadId>","upload":"<upload id>"}
///
/// JSON and not a joined string, because both the upload id and the composed session
/// identity may contain `/`, and a delimiter that either side may contain is a parse that
/// is not total. Encoder and decoder are pure and are tier 1.
///
/// A task whose description this transport did not mint is cancelled and never read as
/// progress. This transport writes exactly one string per (upload, session, chunk), so a
/// description is ours only if it is byte-for-byte the string this transport writes:
/// `init?(decoding:)` reads the fields, then re-encodes and compares. That one rule, not
/// a list, refuses a missing key, a fourth key, a chunk below one, a session that does not
/// parse, a boolean or floating-point chunk that NSNumber bridging would read as an
/// integer, reordered keys, whitespace and an escaped slash — and says so with `nil`
/// rather than a value that would be read as evidence about some upload.
struct TaskDescription: Hashable, Sendable {
    let upload: UploadID
    let session: TransportSessionID
    let chunk: ChunkID

    init(upload: UploadID, session: TransportSessionID, chunk: ChunkID) {
        self.upload = upload
        self.session = session
        self.chunk = chunk
    }

    /// The string the task is created under. Sorted keys, and `/` written as itself:
    /// without `.withoutEscapingSlashes` the session comes out as `r\/u`, which is not the
    /// string ADR-0007 §4 shows.
    var encoded: String {
        let object: [String: Any] = [
            Key.chunk: chunk.ordinal,
            Key.session: session.rawValue,
            Key.upload: upload.rawValue,
        ]
        // Three scalars under three string keys: the serialiser cannot refuse this, and
        // if it ever did the description would be a string no task should be created under.
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// `nil` unless `string` is a JSON object with exactly the three keys, a `chunk` that is
    /// an integer of one or more, a `session` that `SessionIdentity.parse` accepts — and,
    /// after all that, the string this transport writes for those values, byte for byte.
    init?(decoding string: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
              let fields = object as? [String: Any],
              Set(fields.keys) == [Key.chunk, Key.session, Key.upload],
              let ordinal = fields[Key.chunk] as? Int, ordinal >= 1,
              let session = fields[Key.session] as? String,
              let upload = fields[Key.upload] as? String,
              (try? SessionIdentity.parse(TransportSessionID(session))) != nil
        else { return nil }
        let candidate = TaskDescription(upload: UploadID(upload),
                                        session: TransportSessionID(session),
                                        chunk: ChunkID(ordinal))
        // Decode, then re-encode: the field reads above admit what a JSON parser admits,
        // and a parser admits more than this transport ever writes.
        guard candidate.encoded == string else { return nil }
        self = candidate
    }

    private enum Key {
        static let chunk = "chunk"
        static let session = "session"
        static let upload = "upload"
    }
}
