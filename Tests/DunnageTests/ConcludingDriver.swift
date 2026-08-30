import DunnageCore
import DunnageDriver

/// A driver that concludes.
///
/// It is the same loop as `UploadDriver` — replay, execute one effect, append what happened,
/// fold, queue what the fold asked for — with one line different: an interruption is
/// recorded as `chunkTransferRefused`. One line, and it is the collapse ADR-0002 exists to
/// remove, arriving on the other side of the boundary from where that ADR removed it.
///
/// Nothing else about it is wrong. It does not count attempts, it does not decide to give
/// up, and every `abandoned` it writes is one Core asked for. That is the point: the fault
/// is upstream of all of those, in what it says happened, and Core's conclusion is then
/// correct about evidence that is false.
///
/// It is written out in full rather than assembled from the real driver, for the reason
/// `MarkerlessEventLog` is: a control that shares code with the thing it is measured against
/// stops being independent of it the first time that code changes.
///
/// It has no timeout and does not need one — nothing in the control's scenario goes silent.
/// The interruptions here are a transport answering "no answer", which is the case the
/// mapping is about. Whether the real driver reaches the same event by its own clock instead
/// is `DriverTimeoutTests`.
struct ConcludingDriver: Sendable {

    private let transport: any UploadTransport
    private let log: any UploadEventLog
    private let clock: any DriverClock

    init(transport: any UploadTransport, log: any UploadEventLog, clock: any DriverClock) {
        self.transport = transport
        self.log = log
        self.clock = clock
    }

    @discardableResult
    func run(_ intent: UploadIntent) async throws -> UploadMachineState {
        var state = UploadTransition.replay(
            try await log.records(for: intent.upload).map(\.event))
        var queue: [UploadEffect] = []
        if case .undeclared = state {
            queue = try await record(.declared(intent), for: intent.upload, into: &state)
        }

        while !state.isTerminal, !queue.isEmpty {
            let effect = queue.removeFirst()
            for produced in try await perform(effect, for: intent.upload, into: &state)
            where !queue.contains(produced) {
                queue.append(produced)
            }
        }
        return state
    }

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
            return try await record(.abandoned(reason), for: upload, into: &state)
        }
    }

    /// The one line. A transfer nobody answered for is written down as a transfer that was
    /// answered, and answered no.
    private static func event(for outcome: TransferOutcome) -> UploadEvent {
        switch outcome {
        case .reportedComplete(let chunk): .chunkTransferReported(chunk)
        case .refused(let chunk):          .chunkTransferRefused(chunk)
        case .interrupted(let chunk):      .chunkTransferRefused(chunk)
        }
    }

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
