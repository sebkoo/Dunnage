// The intent model: what the user asked for, and how Core divides it.
//
// Nothing here reaches a network, a disk, a clock or an entropy source. Core is pure;
// those enter only through injected protocols.

/// Identity of one upload, as the application means it.
public struct UploadID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Where the payload is going. Opaque to Core: never parsed, never compared
/// structurally, never a source of authority. Carried so that replaying the log alone
/// reconstructs the whole intent, destination included.
public struct DestinationRef: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Identity of one chunk within one upload's plan. A 1-based ordinal assigned by
/// `ChunkPlan`; the first chunk is ordinal 1.
///
/// This is Core's own numbering. A transport that needs some other numbering — S3 part
/// numbers, say — maps to it at the boundary. Core does not adopt a vendor's scheme.
public struct ChunkID: Hashable, Sendable, CustomStringConvertible {
    public let ordinal: Int
    public init(_ ordinal: Int) {
        precondition(ordinal >= 1, "chunk ordinals are 1-based")
        self.ordinal = ordinal
    }
    public var description: String { "chunk \(ordinal)" }
}

/// A position in the payload, in bytes from the start.
public struct ByteOffset: Hashable, Comparable, Sendable {
    public let value: Int
    public init(_ value: Int) {
        precondition(value >= 0, "byte offsets are non-negative")
        self.value = value
    }
    public static func < (lhs: ByteOffset, rhs: ByteOffset) -> Bool { lhs.value < rhs.value }
}

/// A half-open span of the payload: `[start, endExclusive)`.
public struct ByteRange: Hashable, Sendable {
    public let start: ByteOffset
    public let endExclusive: ByteOffset

    public init(start: ByteOffset, endExclusive: ByteOffset) {
        precondition(start <= endExclusive, "a byte range does not run backwards")
        self.start = start
        self.endExclusive = endExclusive
    }

    public var count: Int { endExclusive.value - start.value }
    public var isEmpty: Bool { count == 0 }
}

/// How Core divides a payload into chunks.
///
/// The division is fixed at declaration time and never renegotiated: a confirmation
/// naming a chunk is meaningless if the chunk's byte range can move underneath it.
public struct ChunkPlan: Hashable, Sendable {
    public let totalBytes: Int
    public let chunkSize: Int

    public init(totalBytes: Int, chunkSize: Int) {
        precondition(totalBytes >= 0, "a payload cannot have negative length")
        precondition(chunkSize > 0, "a chunk size of zero would not terminate")
        self.totalBytes = totalBytes
        self.chunkSize = chunkSize
    }

    /// Ceiling division: a trailing partial chunk is a chunk. Integer division here
    /// would silently drop the remainder, which is the gap the partition test names.
    public var chunkCount: Int { (totalBytes + chunkSize - 1) / chunkSize }

    /// A zero-byte payload has no chunks. Empty is a legitimate partition of nothing,
    /// not a degenerate one-empty-chunk plan.
    public var chunks: [ChunkID] {
        chunkCount == 0 ? [] : (1...chunkCount).map(ChunkID.init)
    }

    /// `nil` when the ordinal is not in this plan. Out of plan is not an empty range;
    /// the two must stay distinguishable.
    public func range(of chunk: ChunkID) -> ByteRange? {
        guard chunk.ordinal <= chunkCount else { return nil }
        let start = (chunk.ordinal - 1) * chunkSize
        return ByteRange(start: ByteOffset(start),
                         endExclusive: ByteOffset(min(start + chunkSize, totalBytes)))
    }
}

/// The durable declaration of what the user asked for.
public struct UploadIntent: Hashable, Sendable {
    public let upload: UploadID
    public let destination: DestinationRef
    public let plan: ChunkPlan

    public init(upload: UploadID, destination: DestinationRef, plan: ChunkPlan) {
        self.upload = upload
        self.destination = destination
        self.plan = plan
    }
}
