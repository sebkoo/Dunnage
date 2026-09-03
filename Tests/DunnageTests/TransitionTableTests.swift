import XCTest
import DunnageCore

final class TransitionTableTests: XCTestCase {

    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        payload: PayloadRef("payload-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    private let session = TransportSessionID("session-1")

    private var emptyReport: Confirmation {
        Confirmation(upload: intent.upload, session: session, progress: .chunks([]))
    }
    private var fullReport: Confirmation {
        Confirmation(upload: intent.upload, session: session,
                     progress: .chunks(Set(intent.plan.chunks)))
    }

    /// One representative event per kind. Exhaustive on purpose: a new event case fails to
    /// compile here before it can quietly slip past the matrix.
    private func representative(_ kind: UploadEventKind) -> UploadEvent {
        switch kind {
        case .declared:               .declared(intent)
        case .transportSessionOpened: .transportSessionOpened(session)
        case .chunkTransferReported:  .chunkTransferReported(ChunkID(1))
        case .chunkTransferRefused:   .chunkTransferRefused(ChunkID(1))
        case .chunkTransferInterrupted: .chunkTransferInterrupted(ChunkID(1))
        case .authorityReported:      .authorityReported(emptyReport)
        case .finalized:              .finalized
        case .abandoned:              .abandoned(.taskCancelled)
        }
    }

    /// Build a representative state by driving the machine to it, so the matrix is only
    /// ever asserted against phases that are actually reachable.
    private func state(in phase: UploadPhase) -> UploadMachineState {
        var current = UploadTransition.initialState
        func step(_ event: UploadEvent) {
            guard case .accepted(let next, _) = UploadTransition.apply(event, to: current) else {
                return XCTFail("cannot reach \(phase.rawValue): \(event) was rejected")
            }
            current = next
        }
        switch phase {
        case .undeclared:
            break
        case .declared:
            step(.declared(intent))
        case .transferring:
            step(.declared(intent)); step(.transportSessionOpened(session))
        case .finalizing:
            step(.declared(intent)); step(.transportSessionOpened(session))
            step(.authorityReported(fullReport))
        case .completed:
            step(.declared(intent)); step(.transportSessionOpened(session))
            step(.authorityReported(fullReport)); step(.finalized)
        case .failed:
            step(.declared(intent)); step(.abandoned(.taskCancelled))
        }
        return current
    }

    private enum Expected: Equatable {
        case accepted(UploadPhase)
        case rejected(RejectionReason)
    }

    /// The whole cross-product, written out. This is the semantic half of totality: the
    /// compiler makes the switch exhaustive, and this table makes each answer deliberate.
    /// Adding a phase or an event kind leaves a hole here and fails the test.
    private let table: [UploadPhase: [UploadEventKind: Expected]] = [
        .undeclared: [
            .declared:               .accepted(.declared),
            .transportSessionOpened: .rejected(.uploadNotDeclared),
            .chunkTransferReported:  .rejected(.uploadNotDeclared),
            .chunkTransferRefused:   .rejected(.uploadNotDeclared),
            .chunkTransferInterrupted: .rejected(.uploadNotDeclared),
            .authorityReported:      .rejected(.uploadNotDeclared),
            .finalized:              .rejected(.uploadNotDeclared),
            .abandoned:              .rejected(.uploadNotDeclared),
        ],
        .declared: [
            .declared:               .rejected(.uploadAlreadyDeclared),
            .transportSessionOpened: .accepted(.transferring),
            .chunkTransferReported:  .rejected(.noTransportSession),
            .chunkTransferRefused:   .rejected(.noTransportSession),
            .chunkTransferInterrupted: .rejected(.noTransportSession),
            .authorityReported:      .rejected(.noTransportSession),
            .finalized:              .rejected(.noTransportSession),
            .abandoned:              .accepted(.failed),
        ],
        .transferring: [
            .declared:               .rejected(.uploadAlreadyDeclared),
            .transportSessionOpened: .rejected(.transportSessionAlreadyOpen),
            .chunkTransferReported:  .accepted(.transferring),
            .chunkTransferRefused:   .accepted(.transferring),   // representative is in the plan
            .chunkTransferInterrupted: .accepted(.transferring),
            .authorityReported:      .accepted(.transferring),   // representative confirms nothing
            .finalized:              .rejected(.notReadyToFinalize),
            .abandoned:              .accepted(.failed),
        ],
        .finalizing: [
            .declared:               .rejected(.uploadAlreadyDeclared),
            .transportSessionOpened: .rejected(.transportSessionAlreadyOpen),
            .chunkTransferReported:  .rejected(.allChunksAlreadyConfirmed),
            .chunkTransferRefused:   .rejected(.allChunksAlreadyConfirmed),
            .chunkTransferInterrupted: .rejected(.allChunksAlreadyConfirmed),
            .authorityReported:      .accepted(.transferring),   // authority no longer holds them
            .finalized:              .accepted(.completed),
            .abandoned:              .accepted(.failed),
        ],
        .completed: [
            .declared:               .rejected(.terminalPhaseIsAbsorbing),
            .transportSessionOpened: .rejected(.terminalPhaseIsAbsorbing),
            .chunkTransferReported:  .rejected(.terminalPhaseIsAbsorbing),
            .chunkTransferRefused:   .rejected(.terminalPhaseIsAbsorbing),
            .chunkTransferInterrupted: .rejected(.terminalPhaseIsAbsorbing),
            .authorityReported:      .rejected(.terminalPhaseIsAbsorbing),
            .finalized:              .rejected(.terminalPhaseIsAbsorbing),
            .abandoned:              .rejected(.terminalPhaseIsAbsorbing),
        ],
        .failed: [
            .declared:               .rejected(.terminalPhaseIsAbsorbing),
            .transportSessionOpened: .rejected(.terminalPhaseIsAbsorbing),
            .chunkTransferReported:  .rejected(.terminalPhaseIsAbsorbing),
            .chunkTransferRefused:   .rejected(.terminalPhaseIsAbsorbing),
            .chunkTransferInterrupted: .rejected(.terminalPhaseIsAbsorbing),
            .authorityReported:      .rejected(.terminalPhaseIsAbsorbing),
            .finalized:              .rejected(.terminalPhaseIsAbsorbing),
            .abandoned:              .rejected(.terminalPhaseIsAbsorbing),
        ],
    ]

    func testTransitionTableIsTotal_EveryStateEventPairHasAnExplicitOutcome() {
        for phase in UploadPhase.allCases {
            guard let row = table[phase] else {
                XCTFail("no stated outcomes for phase \(phase.rawValue)")
                continue
            }
            let start = state(in: phase)
            for kind in UploadEventKind.allCases {
                guard let want = row[kind] else {
                    XCTFail("(\(phase.rawValue), \(kind.rawValue)) has no stated outcome")
                    continue
                }
                let pair = "(\(phase.rawValue), \(kind.rawValue))"
                switch (UploadTransition.apply(representative(kind), to: start), want) {
                case (.accepted(let next, _), .accepted(let wantPhase)):
                    XCTAssertEqual(next.phase, wantPhase, "\(pair) reached the wrong phase")
                case (.rejected(let reason), .rejected(let wantReason)):
                    XCTAssertEqual(reason, wantReason, "\(pair) was rejected for the wrong reason")
                case (.accepted(let next, _), .rejected(let wantReason)):
                    XCTFail("\(pair) was accepted into \(next.phase.rawValue); expected rejection \(wantReason)")
                case (.rejected(let reason), .accepted(let wantPhase)):
                    XCTFail("\(pair) was rejected as \(reason); expected acceptance into \(wantPhase.rawValue)")
                }
            }
        }
    }

    /// Terminal means terminal. Rejection is not enough on its own: the state a rejected
    /// event leaves behind must be the state that was there before it.
    func testTerminalStateIsAbsorbing_EventAfterCompletionIsRejectedWithReason() {
        for phase in [UploadPhase.completed, .failed] {
            let terminal = state(in: phase)
            XCTAssertTrue(terminal.isTerminal, "\(phase.rawValue) should be terminal")

            for kind in UploadEventKind.allCases {
                let outcome = UploadTransition.apply(representative(kind), to: terminal)
                guard case .rejected(let reason) = outcome else {
                    XCTFail("\(kind.rawValue) escaped \(phase.rawValue)")
                    continue
                }
                XCTAssertEqual(reason, .terminalPhaseIsAbsorbing,
                               "\(kind.rawValue) in \(phase.rawValue) needs the absorbing reason")
                XCTAssertEqual(state(in: phase), terminal,
                               "\(kind.rawValue) altered \(phase.rawValue)")
            }
        }
    }

    /// Core asks before it sends. Opening a transport operation produces a question for
    /// the authority, never a transfer: an upload whose session is fresh is not assumed to
    /// be an upload the authority holds nothing for, and the answer is what gets planned
    /// against.
    func testEffectSequenceForACleanUploadAsksBeforeItSends() {
        var current = UploadTransition.initialState

        func step(_ event: UploadEvent, _ file: StaticString = #filePath, _ line: UInt = #line)
        -> [UploadEffect] {
            guard case .accepted(let next, let effects) = UploadTransition.apply(event, to: current)
            else {
                XCTFail("\(event) was rejected in \(current.phase.rawValue)", file: file, line: line)
                return []
            }
            current = next
            return effects
        }

        XCTAssertEqual(step(.declared(intent)), [.openTransportSession(intent)])
        XCTAssertEqual(current.phase, .declared)

        XCTAssertEqual(step(.transportSessionOpened(session)),
                       [.askAuthorityForConfirmedProgress(intent.upload, session)],
                       "opening a session must ask the authority, not start sending")
        XCTAssertEqual(current.phase, .transferring)

        XCTAssertEqual(step(.authorityReported(emptyReport)),
                       [.send(ResumePlan.derive(for: intent, given: .chunks([])).transfers,
                              intent, session, after: .zero)],
                       "an authority holding nothing leaves the whole payload to send")
        XCTAssertEqual(current.phase, .transferring)

        XCTAssertEqual(step(.authorityReported(fullReport)),
                       [.finalize(intent.upload, session)],
                       "a fully confirmed upload asks for the object to be created")
        XCTAssertEqual(current.phase, .finalizing)

        XCTAssertEqual(step(.finalized), [], "completion is the end; it schedules nothing")
        XCTAssertEqual(current.phase, .completed)
    }

    /// A transport saying "that transfer finished" is an observation, not an authority's
    /// statement. It must move nothing: Core never infers progress from bytes it handed to
    /// a transport, it goes and asks.
    func testTransportReportingATransferCompleteDoesNotConfirmAnything() {
        let before = state(in: .transferring)
        guard case .accepted(let after, let effects) =
                UploadTransition.apply(.chunkTransferReported(ChunkID(1)), to: before) else {
            return XCTFail("a transfer report in .transferring is a normal occurrence")
        }
        XCTAssertEqual(after, before, "a transport's report changed confirmed progress")
        XCTAssertEqual(effects, [.askAuthorityForConfirmedProgress(intent.upload, session)],
                       "a transfer report must send Core to ask the authority")
    }
}
