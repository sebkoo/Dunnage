// The transition table.
//
// Pure: a function from (state, event) to an outcome. Effects come back as data and a
// driver executes them. No I/O happens here, ever.

/// Why an event was not applied.
public enum RejectionReason: Hashable, Sendable {
    /// The event needs an intent that is not on record.
    case uploadNotDeclared
    /// A second declaration for an upload that already has one.
    case uploadAlreadyDeclared
    /// The event needs an open transport operation.
    case noTransportSession
    /// A transport operation is already open. Replacing one is a separate decision and is
    /// not made here.
    case transportSessionAlreadyOpen
    /// Finalization was never asked for, so the object cannot be reported as existing.
    case notReadyToFinalize
    /// Every planned chunk is already confirmed; there is nothing left to transfer.
    case allChunksAlreadyConfirmed
    /// The phase is terminal. No event leaves it.
    case terminalPhaseIsAbsorbing
}

/// Work for the driver. Data, not behaviour.
public enum UploadEffect: Hashable, Sendable {
    case openTransportSession(UploadID)
    case askAuthorityForConfirmedProgress(UploadID, TransportSessionID)
    case send([PlannedTransfer], TransportSessionID)
    case finalize(UploadID, TransportSessionID)
}

/// The result of offering an event to the machine. Every pair produces one of these; there
/// is no third answer and no silent no-op.
public enum TransitionOutcome: Hashable, Sendable {
    case accepted(UploadMachineState, [UploadEffect])
    case rejected(RejectionReason)
}

public enum UploadTransition {

    public static let initialState = UploadMachineState.undeclared

    /// No `default:`. Every non-terminal phase enumerates every event kind, so adding a
    /// case to either enum is a compile error rather than a silent fallthrough. The two
    /// terminal rows match on the phase alone: absorbing every event is the deliberate
    /// semantic there, and a newly added event must be absorbed too. The matrix test
    /// still has to state the new pair.
    public static func apply(_ event: UploadEvent,
                             to state: UploadMachineState) -> TransitionOutcome {
        switch (state, event) {

        // ---- undeclared: only a declaration means anything ----

        case (.undeclared, .declared(let intent)):
            return .accepted(.declared(intent: intent),
                             [.openTransportSession(intent.upload)])

        case (.undeclared, .transportSessionOpened),
             (.undeclared, .chunkTransferReported),
             (.undeclared, .authorityReported),
             (.undeclared, .finalized),
             (.undeclared, .abandoned):
            return .rejected(.uploadNotDeclared)

        // ---- declared: waiting for a transport operation ----

        case (.declared, .declared):
            return .rejected(.uploadAlreadyDeclared)

        case (.declared(let intent), .transportSessionOpened(let session)):
            // Ask before sending. A fresh session is not assumed to hold nothing; Core
            // asks the authority and plans from the answer.
            return .accepted(
                .transferring(intent: intent, session: session, confirmed: nil),
                [.askAuthorityForConfirmedProgress(intent.upload, session)])

        case (.declared, .chunkTransferReported),
             (.declared, .authorityReported),
             (.declared, .finalized):
            return .rejected(.noTransportSession)

        case (.declared(let intent), .abandoned(let reason)):
            return .accepted(.failed(intent: intent, reason: reason), [])

        // ---- transferring: a transport operation is open ----

        case (.transferring, .declared):
            return .rejected(.uploadAlreadyDeclared)

        case (.transferring, .transportSessionOpened):
            return .rejected(.transportSessionAlreadyOpen)

        case (.transferring(let intent, let session, _), .chunkTransferReported):
            // The state is returned untouched. A transport's report is an observation;
            // it does not confirm anything. All it does is send Core to ask.
            return .accepted(state, [.askAuthorityForConfirmedProgress(intent.upload, session)])

        case (.transferring(let intent, let session, _), .authorityReported(let confirmation)):
            return settle(intent: intent, session: session,
                          progress: confirmation.progress,
                          finalizeAlreadyRequested: false)

        case (.transferring, .finalized):
            return .rejected(.notReadyToFinalize)

        case (.transferring(let intent, _, _), .abandoned(let reason)):
            return .accepted(.failed(intent: intent, reason: reason), [])

        // ---- finalizing: everything confirmed, object not yet created ----

        case (.finalizing, .declared):
            return .rejected(.uploadAlreadyDeclared)

        case (.finalizing, .transportSessionOpened):
            return .rejected(.transportSessionAlreadyOpen)

        case (.finalizing, .chunkTransferReported):
            return .rejected(.allChunksAlreadyConfirmed)

        case (.finalizing(let intent, let session, _), .authorityReported(let confirmation)):
            return settle(intent: intent, session: session,
                          progress: confirmation.progress,
                          finalizeAlreadyRequested: true)

        case (.finalizing(let intent, _, _), .finalized):
            return .accepted(.completed(intent: intent), [])

        case (.finalizing(let intent, _, _), .abandoned(let reason)):
            return .accepted(.failed(intent: intent, reason: reason), [])

        // ---- terminal: absorbing ----

        case (.completed, _), (.failed, _):
            return .rejected(.terminalPhaseIsAbsorbing)
        }
    }

    /// Fold a fresh statement from the authority into the state.
    ///
    /// Always planned against what the authority says *now*. An authority that has
    /// forgotten parts it previously held reports less, and the plan grows back to cover
    /// what it no longer holds; nothing is carried over from an earlier report.
    private static func settle(intent: UploadIntent,
                               session: TransportSessionID,
                               progress: ConfirmedProgress,
                               finalizeAlreadyRequested: Bool) -> TransitionOutcome {
        let remaining = ResumePlan.derive(for: intent, given: progress).transfers

        guard remaining.isEmpty else {
            return .accepted(
                .transferring(intent: intent, session: session, confirmed: progress),
                [.send(remaining, session)])
        }
        return .accepted(
            .finalizing(intent: intent, session: session, confirmed: progress),
            finalizeAlreadyRequested ? [] : [.finalize(intent.upload, session)])
    }
}

extension UploadTransition {

    /// Fold a recorded sequence into the state it produces.
    ///
    /// Effects are discarded. Replay reconstructs what is true, it does not re-perform what
    /// was done; re-emitting effects here would re-send bytes on every cold start.
    ///
    /// A rejected event leaves the state untouched. The log records what happened, and that
    /// includes events the machine had no rule for in the phase they arrived in — replay
    /// has to be deterministic about those rather than pretend they were never written.
    ///
    /// `from` exists so that a prefix can be replayed once and continued later. Nothing
    /// uses that yet; it is the property that would make a checkpoint cache legal, and it
    /// is asserted rather than assumed.
    public static func replay(_ events: [UploadEvent],
                              from state: UploadMachineState = initialState) -> UploadMachineState {
        events.reduce(state) { current, event in
            switch apply(event, to: current) {
            case .accepted(let next, _): next
            case .rejected:              current
            }
        }
    }
}
