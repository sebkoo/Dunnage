import DunnageCore

/// Executes Core's effects and records what a transport answered.
///
/// ```
/// replay the log ─▶ execute one effect ─▶ append what happened
///        ▲                                        │
///        └───────── fold, and queue what the fold asked for ◀─┘
/// ```
///
/// It concludes nothing. It does not decide that a transfer failed, it does not count
/// attempts, and it does not give up on an upload — those are Core's, derived from the log,
/// and the driver's whole job is to put things on that log and do what the fold asks for.
///
/// **It has no state of its own.** Three injected collaborators and nothing else: no
/// counters, no cache, no notion of where an upload got to. That is not an economy, it is
/// ADR-0003 §2 in the type system. A driver with a field is a driver with a second answer to
/// a question the log already answers, and then a rule for what to do when the two disagree.
///
/// See `docs/adr/0005-the-driver-and-the-clock-it-waits-behind.md`.
public struct UploadDriver: Sendable {

    private let transport: any UploadTransport
    private let log: any UploadEventLog
    private let clock: any DriverClock
    private let quietAfter: Duration

    public init(transport: any UploadTransport,
                log: any UploadEventLog,
                clock: any DriverClock,
                quietAfter: Duration) {
        precondition(quietAfter > .zero, "a transfer given no time to answer is never given one")
        self.transport = transport
        self.log = log
        self.clock = clock
        self.quietAfter = quietAfter
    }

    /// Declare an upload and drive it as far as it goes: until nothing is outstanding, or
    /// until it reaches a terminal phase.
    ///
    /// Returns the state the log now derives. An upload the log has already seen is not
    /// declared a second time — it is picked up from wherever the log left it, which is the
    /// same thing `resume(_:)` does with an identifier alone.
    @discardableResult
    public func run(_ intent: UploadIntent) async throws -> UploadMachineState {
        var state = UploadTransition.replay(
            try await log.records(for: intent.upload).map(\.event))

        if case .undeclared = state {
            try await record(.declared(intent), for: intent.upload, into: &state)
        }
        return try await drive(intent.upload, state: &state,
                               queue: Self.outstandingWork(in: state))
    }

    /// Pick up an upload the log already knows about, and drive it as far as it goes.
    @discardableResult
    public func resume(_ upload: UploadID) async throws -> UploadMachineState {
        var state = UploadTransition.replay(try await log.records(for: upload).map(\.event))
        return try await drive(upload, state: &state,
                               queue: Self.outstandingWork(in: state))
    }

    /// What a state has outstanding, for a driver that has just picked it up.
    ///
    /// `UploadTransition.replay` discards effects on purpose — re-emitting them would
    /// re-send bytes on every cold start — so a state arriving from the log has no work
    /// attached to it and needs a rule. The rule is the weakest effect each phase already
    /// produces on entry.
    ///
    /// `send` is not on this list and cannot be. A resumed upload asks before it sends, so
    /// nothing goes out against an answer given before the process died — an answer the
    /// authority may well have moved past.
    ///
    /// No `default:`, for the reason the transition table has none: a new phase should be a
    /// compile error here rather than an upload that silently has nothing to do.
    private static func outstandingWork(in state: UploadMachineState) -> [UploadEffect] {
        switch state {
        case .undeclared:
            []                                                  // the log knows no such upload
        case .declared(let intent):
            [.openTransportSession(intent)]
        case .transferring(let intent, let session, _, _):
            [.askAuthorityForConfirmedProgress(intent.upload, session)]
        case .finalizing(let intent, let session, _, _):
            [.finalize(intent.upload, session)]
        case .completed, .failed:
            []                                                  // terminal, and absorbing
        }
    }

    // MARK: the loop

    /// Execute effects until there are none, or until the phase is terminal.
    ///
    /// The queue holds **distinct** effects. Five transfers in one round produce five
    /// events, each of which folds to the same "ask the authority", and two identical
    /// questions are one question. Without that the second answer would produce a second
    /// `send` for chunks the first had already put in flight — one round, two transfers per
    /// chunk, and ADR-0003 §1's "charged at most once per answer" quietly over-charging.
    private func drive(_ upload: UploadID,
                       state: inout UploadMachineState,
                       queue: [UploadEffect]) async throws -> UploadMachineState {
        var queue = queue
        while !state.isTerminal, !queue.isEmpty {
            let effect = queue.removeFirst()
            for produced in try await perform(effect, for: upload, into: &state)
            where !queue.contains(produced) {
                queue.append(produced)
            }
        }
        return state
    }

    /// Do one effect, and hand back whatever the events it produced asked for next.
    ///
    /// A thrown error becomes no event. There is nothing in the alphabet that means "the
    /// request could not be made", and inventing a mapping would be the synthesis ADR-0002
    /// forbids: `unknownSession` is an answer about the operation, not about a chunk. So the
    /// log is left as it is and the error goes out to the caller, which means a later run
    /// replays to exactly the state this one started from.
    private func perform(_ effect: UploadEffect,
                         for upload: UploadID,
                         into state: inout UploadMachineState) async throws -> [UploadEffect] {
        switch effect {
        case .openTransportSession(let intent):
            let session = try await transport.openSession(for: intent)
            return try await record(.transportSessionOpened(session), for: upload, into: &state)

        case .askAuthorityForConfirmedProgress(_, let session):
            let confirmation = try await transport.confirmedProgress(in: session)
            return try await record(.authorityReported(confirmation), for: upload, into: &state)

        case .send(let transfers, let session, let after):
            // Before the transfer, not after it and not instead of it. This is the only
            // place backoff happens.
            try await clock.wait(for: after)

            var produced: [UploadEffect] = []
            for transfer in transfers {
                let outcome = try await answer(for: transfer, in: session)
                for next in try await record(Self.event(for: outcome), for: upload, into: &state)
                where !produced.contains(next) {
                    produced.append(next)
                }
            }
            return produced

        case .finalize(_, let session):
            try await transport.finalize(session)
            return try await record(.finalized, for: upload, into: &state)

        case .abandon(_, let reason):
            // The one place `.abandoned` is written, and it is written because Core asked.
            return try await record(.abandoned(reason), for: upload, into: &state)
        }
    }

    /// Hand a transfer over, and stop waiting for the answer after `quietAfter`.
    ///
    /// Stopping produces `.interrupted`, because that is already what "no answer arrived"
    /// means. There is no third outcome and no duration on the event, so a transport that
    /// answered "no answer" and a driver that stopped waiting for one are the same fact, and
    /// Core cannot tell them apart — which is the point.
    ///
    /// It does not say the transfer failed: Core's response is to ask the authority, and if
    /// the bytes did land the next answer says so and the chunk is never sent again. The
    /// timeout is safe *because* of ADR-0002, and it is charged nothing for the same reason.
    ///
    /// It does not say the transfer stopped either. Here the driver stops waiting and the
    /// in-process transfer stops with it; a background `URLSession` transfer would not, and
    /// the event would still be true, because the event is about the answer. That the two
    /// coincide is a property of this phase's transport and not of the design.
    private func answer(for transfer: PlannedTransfer,
                        in session: TransportSessionID) async throws -> TransferOutcome {
        try await withThrowingTaskGroup(of: TransferOutcome?.self) { group in
            group.addTask { try await transport.send(transfer, in: session) }
            group.addTask {
                try await clock.wait(for: quietAfter)
                return nil                       // the deadline came, and no answer with it
            }

            // Whichever settles first. A transport that throws rethrows here, and ADR-0005
            // §8 says what that means: no event, and the round stops.
            let first = try await group.next()!

            // The loser is cancelled and its failure is discarded, because a wait this
            // driver abandoned is not an answer about this transfer. Errors from children
            // never taken from the group are dropped when the body returns; that this
            // driver depends on it is why it is written down.
            group.cancelAll()
            return first ?? .interrupted(transfer.chunk)
        }
    }

    /// The whole of the driver's interpretation of a transport's answer: one event each,
    /// nothing synthesised and nothing collapsed.
    ///
    /// A driver that turned an interruption into a refusal would spend a retry budget on
    /// chunks that were never in trouble, and the upload would give up while the authority
    /// was holding most of it. See ADR-0002.
    private static func event(for outcome: TransferOutcome) -> UploadEvent {
        switch outcome {
        case .reportedComplete(let chunk): .chunkTransferReported(chunk)
        case .refused(let chunk):          .chunkTransferRefused(chunk)
        case .interrupted(let chunk):      .chunkTransferInterrupted(chunk)
        }
    }

    /// Append, then fold. The order is the invariant.
    ///
    /// `Attempts` is derived from the log, so a refusal still in memory when the process
    /// goes away is an attempt that never happened. A driver that collected a round's
    /// answers and appended them together would lose a whole round's tally to one process
    /// death, and an upload that dies on every attempt would retry for ever — the exact
    /// failure a retry budget exists to stop.
    ///
    /// An event the machine has no rule for in this phase is still appended. The log records
    /// what happened, and `UploadTransition.replay` is already explicit about folding those
    /// to no change.
    @discardableResult
    private func record(_ event: UploadEvent,
                        for upload: UploadID,
                        into state: inout UploadMachineState) async throws -> [UploadEffect] {
        try await log.append([event], for: upload)

        switch UploadTransition.apply(event, to: state) {
        case .accepted(let next, let effects):
            state = next
            return effects
        case .rejected:
            return []
        }
    }
}
