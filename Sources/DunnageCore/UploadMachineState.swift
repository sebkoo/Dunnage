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
    /// asked — which is not the same as an authority that holds nothing.
    case transferring(intent: UploadIntent,
                      session: TransportSessionID,
                      confirmed: ConfirmedProgress?)

    /// Every planned chunk is confirmed and finalization has been asked for. The
    /// confirmation is not optional here: this phase is unreachable without one.
    case finalizing(intent: UploadIntent,
                    session: TransportSessionID,
                    confirmed: ConfirmedProgress)

    /// Terminal. The authority reported the object exists.
    case completed(intent: UploadIntent)

    /// Terminal. The upload was given up on, and the class of failure is retained because
    /// the classes have different recovery paths.
    case failed(intent: UploadIntent, reason: FailureReason)

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
