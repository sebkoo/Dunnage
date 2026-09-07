import XCTest
import DunnageCore

/// The negative control's triple: the contract it keeps, the failure it demonstrates, and the
/// contrast that makes the difference attributable to the one thing that differs.
///
/// **Contract, control, contrast, in that order** (spec §7), which is the shape phase 4a's own
/// control takes in `cloud/test/negative-control.test.ts` and phase 5's in
/// `ForgetfulTransportTests`. The order is an argument rather than a filing scheme: the control
/// has to be a fair instrument before it is a demonstration, and only then is the difference
/// the third test shows attributable to the carried confirmation rather than to some second
/// fault.
///
/// Pure and deterministic: no clock, no socket, no disk, no double but this one.
final class ReplacementControlTests: XCTestCase {

    // chunks 1...5, four bytes each
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        payload: PayloadRef("payload-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    private let dead = TransportSessionID("session-1")
    private let live = TransportSessionID("session-2")

    private func held(_ chunks: Set<ChunkID>, from session: TransportSessionID) -> UploadEvent {
        .authorityReported(Confirmation(upload: intent.upload, session: session,
                                        progress: .chunks(chunks)))
    }

    /// One representative event per kind, exhaustive on purpose: a new event case fails to
    /// compile here before it can slip past the comparison below.
    private func representative(_ kind: UploadEventKind) -> UploadEvent {
        switch kind {
        case .declared:                 .declared(intent)
        case .transportSessionOpened:   .transportSessionOpened(dead)
        case .transportSessionLost:     .transportSessionLost(dead)
        case .chunkTransferReported:    .chunkTransferReported(ChunkID(1))
        case .chunkTransferRefused:     .chunkTransferRefused(ChunkID(1))
        case .chunkTransferInterrupted: .chunkTransferInterrupted(ChunkID(1))
        case .authorityReported:        held([], from: dead)
        case .finalized:                .finalized
        case .abandoned:                .abandoned(.taskCancelled)
        }
    }

    /// Drive both machines to the same phase with the same events, so what is compared after
    /// is the rule and not the road taken to it. No sequence here contains a loss.
    private func both(in phase: UploadPhase) -> (real: UploadMachineState, control: CredulousReplacement) {
        var control = CredulousReplacement()
        var real = UploadTransition.initialState
        func step(_ event: UploadEvent) {
            _ = control.apply(event)
            if case .accepted(let next, _) = UploadTransition.apply(event, to: real) { real = next }
        }
        switch phase {
        case .undeclared:
            break
        case .declared:
            step(.declared(intent))
        case .transferring:
            step(.declared(intent)); step(.transportSessionOpened(dead))
        case .finalizing:
            step(.declared(intent)); step(.transportSessionOpened(dead))
            step(held(Set(intent.plan.chunks), from: dead))
        case .completed:
            step(.declared(intent)); step(.transportSessionOpened(dead))
            step(held(Set(intent.plan.chunks), from: dead)); step(.finalized)
        case .failed:
            step(.declared(intent)); step(.abandoned(.taskCancelled))
        }
        return (real, control)
    }

    // MARK: contract

    /// The whole cross-product, and the control must answer every pair exactly as the real
    /// table does. It can: until a loss has been seen it has carried nothing, so even the loss
    /// rows themselves return the real outcome — they only remember on the way past.
    ///
    /// Every differing pair is collected and named, not the first. Evidence naming one pair of
    /// fifty-four is worse than evidence naming fifty-four, and **a control that also broke
    /// something else would prove nothing about the one thing**, which is why this test is the
    /// first of the three and not an afterthought to them.
    func testACredulousReplacementKeepsEveryOtherRuleTheRealOneKeeps() {
        var differing: [String] = []
        for phase in UploadPhase.allCases {
            for kind in UploadEventKind.allCases {
                let (real, base) = both(in: phase)
                var control = base
                let event = representative(kind)
                let mine = control.apply(event)
                let theirs = UploadTransition.apply(event, to: real)
                if mine != theirs {
                    differing.append("(\(phase.rawValue), \(kind.rawValue)): control \(mine), real \(theirs)")
                }
            }
        }
        XCTAssertEqual(differing, [],
                       "the control differs where it must not, and every differing pair is listed above")
    }

    // MARK: control

    /// The failure mode, kept working. After a replacement the control plans from what the
    /// dead operation was confirmed to hold, so the chunks that operation held are never sent
    /// to an authority that does not hold them — and the upload would finalize over parts
    /// that do not exist.
    ///
    /// It is never "fixed": if this ever schedules the whole plan, the control has been broken.
    func testACredulousReplacementSchedulesNothingForPartsTheNewAuthorityDoesNotHold() {
        var control = CredulousReplacement()
        _ = control.apply(.declared(intent))
        _ = control.apply(.transportSessionOpened(dead))
        _ = control.apply(held([ChunkID(1), ChunkID(2)], from: dead))
        _ = control.apply(.transportSessionLost(dead))
        let outcome = control.apply(.transportSessionOpened(live))

        guard case .accepted(let next, let effects) = outcome else {
            return XCTFail("the control opens the replacement; it is a control, not a wall")
        }
        guard effects.count == 1, case .send(let transfers, _, let session, _) = effects[0] else {
            return XCTFail("the control plans instead of asking, so the reopen is one send: got \(effects)")
        }
        XCTAssertEqual(session, live, "the send names the replacement")
        XCTAssertEqual(Set(transfers.map(\.chunk)), [ChunkID(3), ChunkID(4), ChunkID(5)],
                       "the failure mode: 1 and 2 are never sent to an authority that has never been asked")
        XCTAssertEqual(next, .transferring(intent: intent, session: live,
                                           confirmed: .chunks([ChunkID(1), ChunkID(2)]),
                                           attempts: Attempts()),
                       "and the state believes the dead operation's confirmation")
    }

    // MARK: contrast

    /// The same events through the real table. It asks before it sends, and on an answer from
    /// an authority holding nothing it schedules every chunk of the plan again.
    ///
    /// The difference from the test above is the carried set and nothing else, because the
    /// contract test has already established that nothing else differs.
    func testTheRealReplacementSchedulesEveryChunkAgain() {
        let afterLoss = UploadTransition.replay(
            [.declared(intent), .transportSessionOpened(dead),
             held([ChunkID(1), ChunkID(2)], from: dead), .transportSessionLost(dead)])
        XCTAssertEqual(afterLoss, .declared(intent: intent),
                       "the loss leaves an intent and no operation, carrying neither field")

        guard case .accepted(let reopened, let asked) =
                UploadTransition.apply(.transportSessionOpened(live), to: afterLoss) else {
            return XCTFail("the replacement must open")
        }
        XCTAssertEqual(asked, [.askAuthorityForConfirmedProgress(intent.upload, live)],
                       "the real replacement asks; it does not plan from what the dead operation was told")

        guard case .accepted(_, let planned) =
                UploadTransition.apply(held([], from: live), to: reopened) else {
            return XCTFail("an authority holding nothing is a normal answer in a fresh operation")
        }
        guard planned.count == 1, case .send(let transfers, _, _, _) = planned[0] else {
            return XCTFail("an upload with everything outstanding is one send: got \(planned)")
        }
        XCTAssertEqual(Set(transfers.map(\.chunk)), Set(intent.plan.chunks),
                       "every chunk again, including the two the dead operation held")
    }
}
