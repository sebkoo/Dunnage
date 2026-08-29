// What is left to send, derived from the intent and whatever the authority has confirmed.
//
// This is where the thesis becomes executable: a confirmed chunk is absent from the plan,
// so it is never handed to a transport a second time.

/// One unit of work: a chunk, and the span of it that still needs sending.
///
/// The span is usually the chunk's whole range. It is a suffix only under an offset-shaped
/// authority whose contiguous prefix ends inside the chunk.
public struct PlannedTransfer: Hashable, Sendable {
    public let chunk: ChunkID
    public let range: ByteRange

    public init(chunk: ChunkID, range: ByteRange) {
        self.chunk = chunk
        self.range = range
    }
}

/// The work remaining for one upload, in chunk order.
public struct ResumePlan: Hashable, Sendable {
    public let upload: UploadID
    public let transfers: [PlannedTransfer]

    public init(upload: UploadID, transfers: [PlannedTransfer]) {
        self.upload = upload
        self.transfers = transfers
    }

    /// Derive the remaining work.
    ///
    /// `confirmed` is `nil` when the authority has not yet been asked. That is not the same
    /// as an authority that holds nothing, but the plan is the same either way; the
    /// difference matters to the state machine, not here.
    public static func derive(for intent: UploadIntent,
                              given confirmed: ConfirmedProgress?) -> ResumePlan {
        let plan = intent.plan
        let done = confirmed?.confirmedChunks(in: plan) ?? []

        let transfers = plan.chunks.compactMap { chunk -> PlannedTransfer? in
            guard !done.contains(chunk), let range = plan.range(of: chunk) else { return nil }

            // A set-shaped authority reports a set, not a frontier: an unconfirmed chunk
            // is unconfirmed whole, whatever its neighbours say. An offset-shaped
            // authority reports a contiguous prefix, which can end inside this chunk —
            // then the bytes below the offset are confirmed and only the suffix is left.
            if case .offset(let offset) = confirmed, offset > range.start {
                return PlannedTransfer(
                    chunk: chunk,
                    range: ByteRange(start: offset, endExclusive: range.endExclusive))
            }
            return PlannedTransfer(chunk: chunk, range: range)
        }
        return ResumePlan(upload: intent.upload, transfers: transfers)
    }
}
