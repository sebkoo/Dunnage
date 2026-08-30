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

    public init(transport: any UploadTransport,
                log: any UploadEventLog,
                clock: any DriverClock) {
        self.transport = transport
        self.log = log
        self.clock = clock
    }

    /// Declare an upload and drive it as far as it goes: until nothing is outstanding, or
    /// until it reaches a terminal phase.
    ///
    /// Returns the state the log now derives. An upload the log has already seen is not
    /// declared twice; picking one up from the log is a separate decision and is not made
    /// here yet.
    @discardableResult
    public func run(_ intent: UploadIntent) async throws -> UploadMachineState {
        var state = UploadTransition.replay(
            try await log.records(for: intent.upload).map(\.event))

        var queue: [UploadEffect] = []
        if case .undeclared = state {
            queue = try await record(.declared(intent), for: intent.upload, into: &state)
        }
        return try await drive(intent.upload, state: &state, queue: queue)
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
                let outcome = try await transport.send(transfer, in: session)
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
