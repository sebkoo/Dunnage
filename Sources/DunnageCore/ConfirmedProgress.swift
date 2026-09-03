// What the transport authority actually guarantees.
//
// See docs/adr/0001-transport-boundary-and-confirmed-progress.md. The short version:
// "part 5 exists" and "bytes 0 through 5 are contiguous" are different claims about
// different things, and Core does not translate one into the other.

/// Identity of one transport operation — the thing an authority scopes its statements to.
/// Opaque to Core: never parsed here, only carried and compared whole. On the S3 transport
/// the raw value is `<ref>/<uploadId>` — it contains the multipart `uploadId` and is not
/// it — and only the transport composes and reads it (ADR-0006 §2). Part 3 of one
/// operation and part 3 of another remain unrelated facts.
public struct TransportSessionID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// What an authority says it durably holds.
///
/// Two cases, because there are two confirmation models and one transport contract yields
/// exactly one of them. They are cases rather than fields precisely so that "both" and
/// "neither" are unrepresentable: a struct with `chunks: Set<ChunkID>?` beside
/// `offset: ByteOffset?` would force Core to carry a runtime rule for states the transport
/// contract says cannot occur.
public enum ConfirmedProgress: Hashable, Sendable {
    /// Set-shaped authority: it enumerates the units it holds, in no particular order and
    /// with no implied contiguity. S3 multipart part enumeration is this shape.
    case chunks(Set<ChunkID>)

    /// Offset-shaped authority: it holds a contiguous prefix and reports where that prefix
    /// ends. The IETF resumable upload protocol is this shape.
    case offset(ByteOffset)
}

extension ConfirmedProgress {
    /// Which chunks of `plan` this progress marks confirmed.
    ///
    /// This is an interpretation of the authority's own statement against a plan. It never
    /// widens the claim.
    public func confirmedChunks(in plan: ChunkPlan) -> Set<ChunkID> {
        switch self {
        case .chunks(let reported):
            // Taken at its word, bounded by the plan. An id the plan does not contain is
            // not confirmable against it.
            return reported.filter { plan.range(of: $0) != nil }

        case .offset(let offset):
            // Wholly below, not merely touched. A chunk the offset falls inside is
            // partially transferred, and partial is not confirmed.
            return Set(plan.chunks.filter { chunk in
                guard let range = plan.range(of: chunk) else { return false }
                return range.endExclusive <= offset
            })
        }
    }
}

/// An authority's statement, carrying what it is a statement *about*.
///
/// A confirmation is authoritative only under the transport's stated identity contract, so
/// it names the upload and the transport operation. A confirmation belonging to one upload
/// identity, or to one transport operation, is never silently applied to another.
public struct Confirmation: Hashable, Sendable {
    public let upload: UploadID
    public let session: TransportSessionID
    public let progress: ConfirmedProgress

    public init(upload: UploadID, session: TransportSessionID, progress: ConfirmedProgress) {
        self.upload = upload
        self.session = session
        self.progress = progress
    }
}
