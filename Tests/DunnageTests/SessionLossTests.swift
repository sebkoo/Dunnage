import XCTest
import DunnageCore

/// ADR-0009. An authority that no longer has a transport operation leaves an upload that is
/// not failed and cannot move. What replaces the operation starts where a fresh one starts.
final class SessionLossTests: XCTestCase {

    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        payload: PayloadRef("payload-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    private let dead = TransportSessionID("session-1")
    private let replacement = TransportSessionID("session-2")

    private func report(_ progress: ConfirmedProgress,
                        from session: TransportSessionID) -> UploadEvent {
        .authorityReported(Confirmation(upload: intent.upload, session: session,
                                        progress: progress))
    }

    /// ADR-0009 §2. The upload returns to `.declared` and the replacement is asked for.
    func testAnOperationTheAuthorityNoLongerHasIsReplaced() {
        let transferring = UploadTransition.replay(
            [.declared(intent), .transportSessionOpened(dead),
             report(.chunks([ChunkID(1), ChunkID(2)]), from: dead)])
        XCTAssertEqual(transferring.phase, .transferring,
                       "the log above must reach a live operation for the loss to be about one")

        guard case .accepted(let next, let effects) =
                UploadTransition.apply(.transportSessionLost(dead), to: transferring) else {
            return XCTFail("a loss naming the open operation is the authority saying it forgot")
        }
        XCTAssertEqual(next, .declared(intent: intent),
                       "an upload whose operation is gone has an intent and no operation")
        XCTAssertEqual(effects, [.openTransportSession(intent)],
                       "the replacement is asked for, and nothing is sent to the operation that is gone")

        guard case .accepted(let reopened, let asks) =
                UploadTransition.apply(.transportSessionOpened(replacement), to: next) else {
            return XCTFail("the replacement must be openable; that is what makes this a recovery")
        }
        XCTAssertEqual(reopened.phase, .transferring)
        XCTAssertEqual(asks, [.askAuthorityForConfirmedProgress(intent.upload, replacement)],
                       "the replacement asks the authority before it sends anything")
    }

    /// ADR-0009 §3. Both drops are one decision, because `.declared` carries neither field.
    func testAReplacementInheritsNeitherTheConfirmationNorTheTallyOfTheOperationItReplaces() {
        let spent = UploadTransition.replay(
            [.declared(intent), .transportSessionOpened(dead),
             report(.chunks([ChunkID(1), ChunkID(2)]), from: dead),
             .chunkTransferRefused(ChunkID(3))])
        XCTAssertEqual(spent.phase, .transferring,
                       "the log above must reach an operation with something confirmed and something charged")

        XCTAssertEqual(UploadTransition.replay([.transportSessionLost(dead)], from: spent),
                       .declared(intent: intent),
                       "the state after a loss holds the intent and nothing the dead operation was told")

        let finalizing = UploadTransition.replay(
            [.declared(intent), .transportSessionOpened(dead),
             report(.chunks(Set(intent.plan.chunks)), from: dead)])
        XCTAssertEqual(finalizing.phase, .finalizing,
                       "the log above must reach a fully confirmed operation")
        XCTAssertEqual(UploadTransition.replay([.transportSessionLost(dead)], from: finalizing),
                       .declared(intent: intent),
                       "a confirmation scoped to the operation that is gone does not survive it")

        // What that costs, stated as behaviour: every chunk again, at a first attempt's wait.
        XCTAssertNotEqual(intent.policy.backoff(beforeAttempt: 1),
                          intent.policy.backoff(beforeAttempt: 2),
                          "if these were equal the wait below would say nothing about the tally")
        let reopened = UploadTransition.replay([.transportSessionOpened(replacement)],
                                               from: .declared(intent: intent))
        guard case .accepted(_, let effects) =
                UploadTransition.apply(report(.chunks([]), from: replacement), to: reopened) else {
            return XCTFail("an authority holding nothing is a normal answer in a fresh operation")
        }
        XCTAssertEqual(effects,
                       [.send(ResumePlan.derive(for: intent, given: .chunks([])).transfers,
                              intent, replacement,
                              after: intent.policy.backoff(beforeAttempt: 1))],
                       "the replacement schedules every chunk, at the wait a first attempt gets")
    }

    /// ADR-0009 §1. A loss is evidence about the operation it names and about nothing else.
    func testALossNamingAnotherTransportOperationChangesNothing() {
        let live: [(String, UploadMachineState)] = [
            ("transferring", UploadTransition.replay(
                [.declared(intent), .transportSessionOpened(dead),
                 report(.chunks([ChunkID(1)]), from: dead)])),
            ("finalizing", UploadTransition.replay(
                [.declared(intent), .transportSessionOpened(dead),
                 report(.chunks(Set(intent.plan.chunks)), from: dead)])),
        ]

        for (phase, state) in live {
            switch UploadTransition.apply(.transportSessionLost(replacement), to: state) {
            case .rejected(let reason):
                XCTAssertEqual(reason, .lossNamesAnotherTransportSession,
                               "\(phase): refused, and the reason must name what was wrong with it")
            case .accepted(let next, let effects):
                XCTFail("\(phase): a loss about another operation was applied — reached \(next.phase.rawValue) with \(effects)")
            }
            XCTAssertEqual(
                UploadTransition.replay([.transportSessionLost(replacement)], from: state), state,
                "\(phase): a rejected loss leaves the state it arrived in")
        }

        // A stale loss replayed off the log must not drop an operation opened after it.
        let derived = UploadTransition.replay(
            [.declared(intent), .transportSessionOpened(dead), .transportSessionLost(dead),
             .transportSessionOpened(replacement), .transportSessionLost(dead)])
        guard case .transferring(_, let session, _, _) = derived else {
            return XCTFail("the log above opens a replacement, so replay ends in a live operation; reached \(derived.phase.rawValue)")
        }
        XCTAssertEqual(session, replacement,
                       "a loss about the operation that is gone must not close the one opened after it")
    }
}
