import Foundation
import DunnageCore

/// The written form of an event.
///
/// Hand-written, and living here rather than in Core, because the bytes on disk are a
/// decision and not a consequence of how Core spells itself. A synthesised `Codable`
/// conformance would derive the format from case names and associated-value labels, so a
/// rename the compiler accepts would change what is already on someone's disk with nothing
/// written down that it had. See ADR-0004 §1.
///
/// The asymmetry between the two directions is deliberate:
///
/// - `encode` switches over `UploadEvent` with no `default:`. A new case in Core is a
///   compile error here, and whoever adds it chooses its written form.
/// - `decode` has a default, and it is the refusal in ADR-0004 §4. That default is the
///   decision, not the absence of one.
public enum LedgerFormat {

    /// The format version written into a ledger's header. Two versions have existed:
    /// 1 wrote no payload, and 2 does. The reader refuses any other version rather than
    /// translating it, and 1 is refused, not read — no version-1 log exists outside the
    /// suite, so a reader for it would be a migration for a file no one has (ADR-0007 §8).
    public static let version = 2

    public static func encode(_ event: UploadEvent) throws -> [UInt8] {
        // Sorted keys, and a set written in ascending order: one event has one written
        // form. A `Set<ChunkID>` has no order of its own, so the format supplies one —
        // otherwise the same event encodes two ways and neither is wrong.
        let data = try JSONSerialization.data(withJSONObject: written(event),
                                              options: [.sortedKeys])
        return [UInt8](data)
    }

    public static func decode(_ payload: [UInt8]) throws -> UploadEvent {
        guard let any = try? JSONSerialization.jsonObject(with: Data(payload)),
              let record = any as? [String: Any] else {
            throw RecordFault.malformed(detail: "a record is a JSON object")
        }
        guard let tag = record["event"] as? String else {
            throw RecordFault.malformed(detail: "a record names its event")
        }

        switch tag {
        case "declared":
            try only(["event", "intent"], in: record, of: tag)
            return .declared(try intent(try object(record, "intent", of: tag)))

        case "transportSessionOpened":
            try only(["event", "session"], in: record, of: tag)
            return .transportSessionOpened(TransportSessionID(try string(record, "session", of: tag)))

        case "chunkTransferReported":
            try only(["chunk", "event"], in: record, of: tag)
            return .chunkTransferReported(try chunk(record, of: tag))

        case "chunkTransferRefused":
            try only(["chunk", "event"], in: record, of: tag)
            return .chunkTransferRefused(try chunk(record, of: tag))

        case "chunkTransferInterrupted":
            try only(["chunk", "event"], in: record, of: tag)
            return .chunkTransferInterrupted(try chunk(record, of: tag))

        case "authorityReported":
            try only(["confirmation", "event"], in: record, of: tag)
            return .authorityReported(try confirmation(try object(record, "confirmation", of: tag)))

        case "finalized":
            try only(["event"], in: record, of: tag)
            return .finalized

        case "abandoned":
            try only(["event", "reason"], in: record, of: tag)
            return .abandoned(try reason(try string(record, "reason", of: tag)))

        default:
            // ADR-0004 §4. The record is complete and this binary has no meaning for it.
            // It is not skipped, not read as far as it goes, and not guessed at.
            throw RecordFault.unknownToken(field: "event", token: tag)
        }
    }

    // MARK: - Writing

    private static func written(_ event: UploadEvent) -> [String: Any] {
        switch event {
        case .declared(let intent):
            ["event": "declared", "intent": written(intent)]
        case .transportSessionOpened(let session):
            ["event": "transportSessionOpened", "session": session.rawValue]
        case .chunkTransferReported(let chunk):
            ["event": "chunkTransferReported", "chunk": chunk.ordinal]
        case .chunkTransferRefused(let chunk):
            ["event": "chunkTransferRefused", "chunk": chunk.ordinal]
        case .chunkTransferInterrupted(let chunk):
            ["event": "chunkTransferInterrupted", "chunk": chunk.ordinal]
        case .authorityReported(let confirmation):
            ["event": "authorityReported", "confirmation": written(confirmation)]
        case .finalized:
            ["event": "finalized"]
        case .abandoned(let reason):
            ["event": "abandoned", "reason": written(reason)]
        }
    }

    private static func written(_ intent: UploadIntent) -> [String: Any] {
        ["upload": intent.upload.rawValue,
         "destination": intent.destination.rawValue,
         "payload": intent.payload.rawValue,
         "plan": ["totalBytes": intent.plan.totalBytes, "chunkSize": intent.plan.chunkSize],
         "policy": ["maxAttemptsPerChunk": intent.policy.maxAttemptsPerChunk,
                    "initialBackoff": written(intent.policy.initialBackoff),
                    "maximumBackoff": written(intent.policy.maximumBackoff)]]
    }

    private static func written(_ confirmation: Confirmation) -> [String: Any] {
        ["upload": confirmation.upload.rawValue,
         "session": confirmation.session.rawValue,
         "progress": written(confirmation.progress)]
    }

    /// The sum type stays a sum type: a shape, and exactly the field that shape carries.
    /// Never two optional fields, which would make "both" and "neither" writable — the
    /// states ADR-0001 §1 deleted at compile time would come back through the disk.
    private static func written(_ progress: ConfirmedProgress) -> [String: Any] {
        switch progress {
        case .chunks(let chunks):
            ["shape": "chunks", "chunks": chunks.map(\.ordinal).sorted()]
        case .offset(let offset):
            ["shape": "offset", "offset": offset.value]
        }
    }

    private static func written(_ duration: Duration) -> [String: Any] {
        ["seconds": duration.components.seconds,
         "attoseconds": duration.components.attoseconds]
    }

    private static func written(_ reason: FailureReason) -> String {
        switch reason {
        case .retriesExhausted: "retriesExhausted"
        case .taskCancelled:    "taskCancelled"
        case .systemTerminated: "systemTerminated"
        case .userForceQuit:    "userForceQuit"
        }
    }

    // MARK: - Reading

    private static func intent(_ object: [String: Any]) throws -> UploadIntent {
        try only(["destination", "payload", "plan", "policy", "upload"], in: object, of: "intent")

        let plan = try self.object(object, "plan", of: "intent")
        try only(["chunkSize", "totalBytes"], in: plan, of: "plan")
        let totalBytes = try integer(plan, "totalBytes", of: "plan")
        let chunkSize = try integer(plan, "chunkSize", of: "plan")
        guard totalBytes >= 0 else { throw RecordFault.malformed(detail: "a payload cannot have negative length") }
        guard chunkSize > 0 else { throw RecordFault.malformed(detail: "a chunk size of zero would not terminate") }
        // Core divides by ceiling, so a plan this wide would overflow the first time it was
        // asked how many chunks it has. The decoder is the trust boundary; refuse it here
        // rather than construct a value that crashes when used.
        guard totalBytes <= Int.max - chunkSize + 1 else {
            throw RecordFault.malformed(detail: "a plan too wide to partition")
        }

        let policy = try self.object(object, "policy", of: "intent")
        try only(["initialBackoff", "maxAttemptsPerChunk", "maximumBackoff"], in: policy, of: "policy")
        let attempts = try integer(policy, "maxAttemptsPerChunk", of: "policy")
        let initial = try duration(try self.object(policy, "initialBackoff", of: "policy"))
        let maximum = try duration(try self.object(policy, "maximumBackoff", of: "policy"))
        guard attempts >= 1 else { throw RecordFault.malformed(detail: "a policy that allows no attempt sends nothing") }
        guard initial >= .zero else { throw RecordFault.malformed(detail: "a backoff does not run backwards") }
        guard maximum >= initial else { throw RecordFault.malformed(detail: "the cap is below the first wait") }

        return UploadIntent(
            upload: UploadID(try string(object, "upload", of: "intent")),
            destination: DestinationRef(try string(object, "destination", of: "intent")),
            payload: PayloadRef(try string(object, "payload", of: "intent")),
            plan: ChunkPlan(totalBytes: totalBytes, chunkSize: chunkSize),
            policy: RetryPolicy(maxAttemptsPerChunk: attempts,
                                initialBackoff: initial,
                                maximumBackoff: maximum))
    }

    private static func confirmation(_ object: [String: Any]) throws -> Confirmation {
        try only(["progress", "session", "upload"], in: object, of: "confirmation")
        return Confirmation(
            upload: UploadID(try string(object, "upload", of: "confirmation")),
            session: TransportSessionID(try string(object, "session", of: "confirmation")),
            progress: try progress(try self.object(object, "progress", of: "confirmation")))
    }

    private static func progress(_ object: [String: Any]) throws -> ConfirmedProgress {
        switch try string(object, "shape", of: "progress") {
        case "chunks":
            try only(["chunks", "shape"], in: object, of: "progress")
            guard let ordinals = object["chunks"] as? [Int] else {
                throw RecordFault.malformed(detail: "a set-shaped progress names its chunks")
            }
            guard ordinals.allSatisfy({ $0 >= 1 }) else {
                throw RecordFault.malformed(detail: "chunk ordinals are 1-based")
            }
            return .chunks(Set(ordinals.map(ChunkID.init)))

        case "offset":
            try only(["offset", "shape"], in: object, of: "progress")
            let value = try integer(object, "offset", of: "progress")
            guard value >= 0 else { throw RecordFault.malformed(detail: "byte offsets are non-negative") }
            return .offset(ByteOffset(value))

        case let shape:
            throw RecordFault.unknownToken(field: "shape", token: shape)
        }
    }

    private static func duration(_ object: [String: Any]) throws -> Duration {
        try only(["attoseconds", "seconds"], in: object, of: "duration")
        return Duration(secondsComponent: Int64(try integer(object, "seconds", of: "duration")),
                        attosecondsComponent: Int64(try integer(object, "attoseconds", of: "duration")))
    }

    private static func reason(_ token: String) throws -> FailureReason {
        switch token {
        case "retriesExhausted": return .retriesExhausted
        case "taskCancelled":    return .taskCancelled
        case "systemTerminated": return .systemTerminated
        case "userForceQuit":    return .userForceQuit
        default:                 throw RecordFault.unknownToken(field: "reason", token: token)
        }
    }

    private static func chunk(_ record: [String: Any], of place: String) throws -> ChunkID {
        let ordinal = try integer(record, "chunk", of: place)
        guard ordinal >= 1 else { throw RecordFault.malformed(detail: "chunk ordinals are 1-based") }
        return ChunkID(ordinal)
    }

    // MARK: - Field access

    /// A field this binary does not have is a refusal, not something to step over. A newer
    /// build that adds a field to an existing event is exactly as unreadable as one that
    /// adds an event, and reading the rest would derive an upload it did not describe.
    private static func only(_ expected: Set<String>,
                             in object: [String: Any],
                             of place: String) throws {
        for key in object.keys.sorted() where !expected.contains(key) {
            throw RecordFault.unknownToken(field: place, token: key)
        }
    }

    private static func string(_ object: [String: Any], _ key: String, of place: String) throws -> String {
        guard let value = object[key] as? String else {
            throw RecordFault.malformed(detail: "\(place).\(key) is a string")
        }
        return value
    }

    private static func object(_ object: [String: Any], _ key: String, of place: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else {
            throw RecordFault.malformed(detail: "\(place).\(key) is an object")
        }
        return value
    }

    /// JSON's `true` bridges to `NSNumber` and casts to `Int` as 1, so a boolean would
    /// arrive as a perfectly good chunk ordinal. Identity against the CoreFoundation
    /// singletons is the check that does not depend on how a number was boxed.
    private static func integer(_ object: [String: Any], _ key: String, of place: String) throws -> Int {
        let boolean = object[key].map { ($0 as AnyObject) === (kCFBooleanTrue as AnyObject)
                                     || ($0 as AnyObject) === (kCFBooleanFalse as AnyObject) } ?? false
        guard !boolean, let value = object[key] as? Int else {
            throw RecordFault.malformed(detail: "\(place).\(key) is an integer")
        }
        return value
    }
}
