// The append-only log's alphabet.
//
// An event is something that happened. It is not, by itself, grounds for a state change:
// the transition table decides what an event means in the phase it arrives in.

/// Why an upload stopped.
///
/// These four are kept apart on purpose. They have different recovery paths, and collapsing
/// them into one "it failed" discards the only information that decides what to do next.
/// Recovery per class is not implemented yet.
public enum FailureReason: Hashable, Sendable {
    /// The connection dropped mid-transfer. Unconfirmed chunks are re-planned against
    /// whatever the authority still holds.
    case networkInterrupted

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
        case .authorityReported:      .authorityReported
        case .finalized:              .finalized
        case .abandoned:              .abandoned
        }
    }
}
