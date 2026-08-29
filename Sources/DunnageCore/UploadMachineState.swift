// The state derived from the log.
//
// State is a sum type, not a struct of optionals. A phase carries exactly the data that
// phase has, so there is no `intent!` and no runtime guard for a combination the model
// says cannot occur. `.finalizing` cannot exist without a confirmation, and the type says
// so; `.transferring` can exist before the authority has been asked, and the type says
// that too.

/// The phase cases with their payloads stripped off, for the transition matrix.
public enum UploadPhase: String, CaseIterable, Hashable, Sendable {
    case undeclared
    case declared
    case transferring
    case finalizing
    case completed
    case failed
}

public enum UploadMachineState: Hashable, Sendable {
    /// Nothing is known. The log is empty.
    case undeclared

    /// The intent is on record; no transport operation is open yet.
    case declared(intent: UploadIntent)

    /// A transport operation is open. `confirmed` is `nil` until the authority has been
    /// asked — which is not the same as an authority that holds nothing. `attempts` is what
    /// each chunk has spent against the intent's retry policy.
    case transferring(intent: UploadIntent,
                      session: TransportSessionID,
                      confirmed: ConfirmedProgress?,
                      attempts: Attempts)

    /// Every planned chunk is confirmed and finalization has been asked for. The
    /// confirmation is not optional here: this phase is unreachable without one.
    ///
    /// The tally comes along rather than being dropped. An authority that later reports
    /// less sends this upload back to `.transferring`, and it should arrive there knowing
    /// what it has already spent rather than with a budget that quietly reset.
    case finalizing(intent: UploadIntent,
                    session: TransportSessionID,
                    confirmed: ConfirmedProgress,
                    attempts: Attempts)

    /// Terminal. The authority reported the object exists.
    case completed(intent: UploadIntent)

    /// Terminal. The upload was given up on, and the class of failure is retained because
    /// the classes have different recovery paths.
    ///
    /// `confirmed` is what the authority last said it held. Giving up is not a reason to
    /// forget it: the confirmed set is the difference between an upload that can be picked
    /// up later and one that starts again from zero. It is `nil` only when the upload was
    /// abandoned before the authority had ever been asked.
    case failed(intent: UploadIntent,
                reason: FailureReason,
                confirmed: ConfirmedProgress?)

    public var phase: UploadPhase {
        switch self {
        case .undeclared:   .undeclared
        case .declared:     .declared
        case .transferring: .transferring
        case .finalizing:   .finalizing
        case .completed:    .completed
        case .failed:       .failed
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed:                          true
        case .undeclared, .declared, .transferring, .finalizing: false
        }
    }
}
