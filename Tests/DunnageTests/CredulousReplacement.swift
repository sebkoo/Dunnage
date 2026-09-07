import DunnageCore

/// The negative control: a replacement that believes the dead operation's confirmation.
///
/// This demonstrates the failure mode ADR-0009 §3 removes. It is not a bug and it is never
/// "fixed": if it ever stops scheduling less than the whole plan after a replacement, the
/// control has been broken and the thesis has lost the thing it is measured against.
///
/// **One difference, and everything else delegated.** Every (state, event) pair goes to
/// `UploadTransition.apply` verbatim except the rows this control exists to change, so the
/// contrast cannot be attributed to a second fault. The difference is expressed across two
/// rows because ADR-0009 §2 established that the loss row's target and the drop are one
/// decision: the loss remembers what the dead operation was confirmed to hold, and the reopen
/// enters `.transferring` with that set and a `.send` derived from it — where the real table
/// enters with `confirmed: nil` and asks the authority before anything is sent.
struct CredulousReplacement {

    private(set) var state = UploadTransition.initialState

    /// What the dead operation was confirmed to hold. The real machine has nowhere to put
    /// this — `.declared` carries neither a confirmation nor a tally — and that absence is
    /// precisely the decision this control undoes.
    private var carried: ConfirmedProgress?

    mutating func apply(_ event: UploadEvent) -> TransitionOutcome {
        let outcome = differing(event) ?? UploadTransition.apply(event, to: state)
        if case .accepted(let next, _) = outcome { state = next }
        return outcome
    }

    /// The rows that differ, and `nil` for every pair that does not.
    ///
    /// The `default:` here is not the one the transition table refuses. This is a selector
    /// over the rows this control changes, not a total table: an event it does not name is
    /// delegated, which is the correct answer for a new case in Core and not a silent gap.
    private mutating func differing(_ event: UploadEvent) -> TransitionOutcome? {
        switch (state, event) {

        // The loss remembers instead of dropping. The row's own outcome is the real one's.
        case (.transferring(_, let session, let confirmed, _), .transportSessionLost(let id))
            where id == session:
            carried = confirmed
            return nil

        case (.finalizing(_, let session, let confirmed, _), .transportSessionLost(let id))
            where id == session:
            carried = confirmed
            return nil

        // And the reopen believes it: it plans from the dead operation's set rather than
        // asking the authority that has never been asked anything.
        case (.declared(let intent), .transportSessionOpened(let session)):
            guard let carried else { return nil }
            return .accepted(
                .transferring(intent: intent, session: session,
                              confirmed: carried, attempts: Attempts()),
                [.send(ResumePlan.derive(for: intent, given: carried).transfers,
                       intent, session, after: intent.policy.backoff(beforeAttempt: 1))])

        default:
            return nil
        }
    }
}
