// The append-only log's alphabet.
//
// An event is something that happened. It is not, by itself, grounds for a state change:
// the transition table decides what an event means in the phase it arrives in.

/// Why an upload was given up on.
///
/// These are kept apart on purpose. They have different recovery paths, and collapsing them
/// into one "it failed" discards the only information that decides what to do next.
/// Recovery per class is not implemented yet.
///
/// Every case here is a statement about the upload as a whole. A dropped connection is not
/// one: it is the absence of an answer about a single chunk, it settles nothing, and it is
/// carried by `UploadEvent.chunkTransferInterrupted`. A `networkInterrupted` case here would
/// say that an interruption is grounds for abandoning an upload, and it is not.
/// See docs/adr/0002-interruption-is-not-a-failure.md.
public enum FailureReason: Hashable, Sendable {
    /// Some chunk spent the last of its retry budget. A decision, taken against a rule that
    /// was on the log before the first byte moved.
    case retriesExhausted

    /// Cancelled from inside the app. Deliberate, and not an error.
    case taskCancelled

    /// The system reclaimed the process. Nothing of ours ran at that moment, so the log is
    /// whatever had already been durably appended.
    case systemTerminated

    /// The user force-quit the app. Distinct from the system reclaiming the process:
    /// the recovery path differs because the system's willingness to relaunch the app for
    /// background events differs.
    case userForceQuit
}

/// Something that happened to an upload.
public enum UploadEvent: Hashable, Sendable {
    /// The user asked for this upload. Carries the whole intent so that replaying the log
    /// alone reconstructs it.
    case declared(UploadIntent)

    /// A transport operation was opened for this upload.
    case transportSessionOpened(TransportSessionID)

    /// A transport said a chunk's transfer finished.
    ///
    /// This is an observation, not a confirmation. The chunk id is recorded because the log
    /// records what happened; the transition table deliberately does not treat it as
    /// progress. "The request returned success" and "this unit is durably known to exist"
    /// are different claims.
    case chunkTransferReported(ChunkID)

    /// A transport answered that a chunk's transfer did not land.
    ///
    /// An answer, and a negative one. It is still not a statement by the authority about
    /// what it holds, so Core records it and goes and asks — but unlike an interruption it
    /// is something learned about this chunk.
    case chunkTransferRefused(ChunkID)

    /// No answer arrived for a chunk's transfer. The connection dropped, or the transfer
    /// stalled; from here the two are the same event.
    ///
    /// This is the weakest observation in the alphabet. It does not say the chunk failed
    /// and it does not say the chunk landed, because the transport is not in a position to
    /// say either. It is on the log because it happened, and because it is the thing that
    /// sends Core to the authority.
    case chunkTransferInterrupted(ChunkID)

    /// The authority stated what it holds. This is the only event that moves confirmed
    /// progress.
    case authorityReported(Confirmation)

    /// The authority reported that the object now exists.
    case finalized

    /// The upload was given up on.
    case abandoned(FailureReason)
}

/// The event cases with their payloads stripped off.
///
/// The transition table's totality is a property of (phase, kind) pairs, so the matrix test
/// enumerates kinds. Adding a case to `UploadEvent` fails to compile here, and then leaves
/// a hole in that matrix.
public enum UploadEventKind: String, CaseIterable, Hashable, Sendable {
    case declared
    case transportSessionOpened
    case chunkTransferReported
    case chunkTransferRefused
    case chunkTransferInterrupted
    case authorityReported
    case finalized
    case abandoned
}

extension UploadEvent {
    public var kind: UploadEventKind {
        switch self {
        case .declared:               .declared
        case .transportSessionOpened: .transportSessionOpened
        case .chunkTransferReported:  .chunkTransferReported
        case .chunkTransferRefused:   .chunkTransferRefused
        case .chunkTransferInterrupted: .chunkTransferInterrupted
        case .authorityReported:      .authorityReported
        case .finalized:              .finalized
        case .abandoned:              .abandoned
        }
    }
}
