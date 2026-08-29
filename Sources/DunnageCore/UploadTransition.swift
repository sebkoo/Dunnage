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
    /// The confirmation names a different upload. Evidence about one upload is not
    /// evidence about another.
    case confirmationForAnotherUpload
    /// The confirmation names a different transport operation. Units are scoped to the
    /// operation that stated them, so this is not evidence about the open one.
    case confirmationFromAnotherTransportSession
    /// The phase is terminal. No event leaves it.
    case terminalPhaseIsAbsorbing
    /// The event names a chunk this upload never planned. It is not evidence about this
    /// upload, so it does not get to spend this upload's retry budget.
    case chunkIsNotInThisPlan
}

/// Work for the driver. Data, not behaviour.
public enum UploadEffect: Hashable, Sendable {
    case openTransportSession(UploadID)
    case askAuthorityForConfirmedProgress(UploadID, TransportSessionID)
    /// Transfer these spans, no sooner than `after` from now.
    ///
    /// The wait is data. Core computes it from the retry policy and the attempts already
    /// spent; the driver is the thing that waits, behind its own injected clock. Nothing in
    /// Core reads a clock, sleeps, or runs a timer.
    case send([PlannedTransfer], TransportSessionID, after: Duration)
    case finalize(UploadID, TransportSessionID)
    /// Give up on this upload: append `.abandoned(reason)`.
    ///
    /// Core asks; it does not enter `.failed` on its own. That is what makes the entry a
    /// decision rather than a drift, and it keeps `.abandoned` the one event that reaches
    /// the terminal phase.
    case abandon(UploadID, FailureReason)
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
             (.undeclared, .chunkTransferRefused),
             (.undeclared, .chunkTransferInterrupted),
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
                .transferring(intent: intent, session: session,
                              confirmed: nil, attempts: Attempts()),
                [.askAuthorityForConfirmedProgress(intent.upload, session)])

        case (.declared, .chunkTransferReported),
             (.declared, .chunkTransferRefused),
             (.declared, .chunkTransferInterrupted),
             (.declared, .authorityReported),
             (.declared, .finalized):
            return .rejected(.noTransportSession)

        case (.declared(let intent), .abandoned(let reason)):
            // Nothing was ever asked of the authority, so there is nothing to keep.
            return .accepted(.failed(intent: intent, reason: reason, confirmed: nil), [])

        // ---- transferring: a transport operation is open ----

        case (.transferring, .declared):
            return .rejected(.uploadAlreadyDeclared)

        case (.transferring, .transportSessionOpened):
            return .rejected(.transportSessionAlreadyOpen)

        case (.transferring(let intent, let session, _, _), .chunkTransferReported):
            // The state is returned untouched. A transport's report is an observation;
            // it does not confirm anything. All it does is send Core to ask.
            return .accepted(state, [.askAuthorityForConfirmedProgress(intent.upload, session)])

        case (.transferring(let intent, let session, _, _), .chunkTransferInterrupted):
            // Untouched too, and the reason it is untouched is the whole invariant. A
            // report and a refusal are answers; this is the absence of one. The chunk is
            // unconfirmed — not failed, and not landed — and nothing here is allowed to
            // decide which. It costs no budget, because nothing was learned. Core asks;
            // the authority settles it.
            return .accepted(state, [.askAuthorityForConfirmedProgress(intent.upload, session)])

        case (.transferring(let intent, let session, let confirmed, let attempts),
              .chunkTransferRefused(let chunk)):
            // The one observation that costs something. It is still not a statement by the
            // authority, so confirmed progress does not move and Core still goes and asks —
            // but the transport answered no about this chunk, and that is an attempt.
            //
            // The plan is checked first because this is the event that spends a budget: a
            // refusal naming a chunk this upload never planned is not evidence about this
            // upload, and it does not get to exhaust it. A report and an interruption need
            // no such guard; they spend nothing.
            guard intent.plan.range(of: chunk) != nil else {
                return .rejected(.chunkIsNotInThisPlan)
            }
            return .accepted(
                .transferring(intent: intent, session: session,
                              confirmed: confirmed, attempts: attempts.charging(chunk)),
                [.askAuthorityForConfirmedProgress(intent.upload, session)])

        case (.transferring(let intent, let session, _, let attempts),
              .authorityReported(let confirmation)):
            return admit(confirmation, for: intent, in: session) {
                settle(intent: intent, session: session,
                       progress: confirmation.progress,
                       attempts: attempts.afterTheAuthorityAnswered(),
                       finalizeAlreadyRequested: false)
            }

        case (.transferring, .finalized):
            return .rejected(.notReadyToFinalize)

        case (.transferring(let intent, _, let confirmed, _), .abandoned(let reason)):
            return .accepted(.failed(intent: intent, reason: reason, confirmed: confirmed), [])

        // ---- finalizing: everything confirmed, object not yet created ----

        case (.finalizing, .declared):
            return .rejected(.uploadAlreadyDeclared)

        case (.finalizing, .transportSessionOpened):
            return .rejected(.transportSessionAlreadyOpen)

        case (.finalizing, .chunkTransferReported),
             (.finalizing, .chunkTransferRefused),
             (.finalizing, .chunkTransferInterrupted):
            return .rejected(.allChunksAlreadyConfirmed)

        case (.finalizing(let intent, let session, _, let attempts),
              .authorityReported(let confirmation)):
            return admit(confirmation, for: intent, in: session) {
                settle(intent: intent, session: session,
                       progress: confirmation.progress,
                       attempts: attempts.afterTheAuthorityAnswered(),
                       finalizeAlreadyRequested: true)
            }

        case (.finalizing(let intent, _, _, _), .finalized):
            return .accepted(.completed(intent: intent), [])

        case (.finalizing(let intent, _, let confirmed, _), .abandoned(let reason)):
            return .accepted(.failed(intent: intent, reason: reason, confirmed: confirmed), [])

        // ---- terminal: absorbing ----

        case (.completed, _), (.failed, _):
            return .rejected(.terminalPhaseIsAbsorbing)
        }
    }

    /// Check a confirmation against the identity it claims before believing any of it.
    ///
    /// A confirmation names an upload and a transport operation. It is evidence about
    /// those two things and nothing else, so one belonging to another upload or another
    /// operation is never silently applied here.
    private static func admit(_ confirmation: Confirmation,
                              for intent: UploadIntent,
                              in session: TransportSessionID,
                              then apply: () -> TransitionOutcome) -> TransitionOutcome {
        guard confirmation.upload == intent.upload else {
            return .rejected(.confirmationForAnotherUpload)
        }
        guard confirmation.session == session else {
            return .rejected(.confirmationFromAnotherTransportSession)
        }
        return apply()
    }

    /// Fold a fresh statement from the authority into the state.
    ///
    /// Always planned against what the authority says *now*. An authority that has
    /// forgotten parts it previously held reports less, and the plan grows back to cover
    /// what it no longer holds; nothing is carried over from an earlier report.
    private static func settle(intent: UploadIntent,
                               session: TransportSessionID,
                               progress: ConfirmedProgress,
                               attempts: Attempts,
                               finalizeAlreadyRequested: Bool) -> TransitionOutcome {
        let remaining = ResumePlan.derive(for: intent, given: progress).transfers

        guard remaining.isEmpty else {
            let next = UploadMachineState.transferring(intent: intent, session: session,
                                                       confirmed: progress, attempts: attempts)

            // Exhaustion is decided here, against a fresh answer from the authority, and
            // nowhere else. A chunk that spent its last attempt and then landed anyway is
            // not in `remaining` at all, and this upload carries on.
            //
            // The effect asks the driver to give up; it does not give up. `.abandoned` stays
            // the only event that reaches a terminal phase, so entering one is a decision on
            // the log rather than a state the fold slid into.
            let spent = remaining.map(\.chunk).contains {
                intent.policy.isExhausted(after: attempts.count(for: $0))
            }
            guard !spent else {
                return .accepted(next, [.abandon(intent.upload, .retriesExhausted)])
            }

            // The wait the next round has earned, computed against the worst-affected
            // outstanding chunk. Refusals are evidence about the endpoint, not only about
            // the one chunk that collected them, and sending the untried chunks straight
            // back into it is the thing backoff exists to prevent.
            let attempt = attempts.highest(among: remaining.map(\.chunk)) + 1
            return .accepted(
                next,
                [.send(remaining, session, after: intent.policy.backoff(beforeAttempt: attempt))])
        }
        return .accepted(
            .finalizing(intent: intent, session: session,
                        confirmed: progress, attempts: attempts),
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
