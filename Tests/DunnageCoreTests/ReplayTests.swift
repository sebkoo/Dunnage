import XCTest
import DunnageCore

final class ReplayTests: XCTestCase {

    private let upload = UploadID("upload-a")
    private let session = TransportSessionID("session-1")
    private var intent: UploadIntent {
        UploadIntent(upload: upload,
                     destination: DestinationRef("destination-a"),
                     plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    }
    private func report(_ progress: ConfirmedProgress) -> UploadEvent {
        .authorityReported(Confirmation(upload: upload, session: session, progress: progress))
    }
    private var everything: ConfirmedProgress { .chunks(Set(intent.plan.chunks)) }

    private struct Scenario {
        let name: String
        let events: [UploadEvent]
        let phase: UploadPhase
    }

    private var scenarios: [Scenario] {
        let opened: [UploadEvent] = [.declared(intent), .transportSessionOpened(session)]
        return [
            Scenario(name: "empty log", events: [], phase: .undeclared),
            Scenario(name: "declared only", events: [.declared(intent)], phase: .declared),
            Scenario(name: "session opened", events: opened, phase: .transferring),
            Scenario(name: "transport reported, authority silent",
                     events: opened + [.chunkTransferReported(ChunkID(1))],
                     phase: .transferring),
            Scenario(name: "partial confirmation",
                     events: opened + [report(.chunks([ChunkID(1), ChunkID(3)]))],
                     phase: .transferring),
            Scenario(name: "offset-shaped partial confirmation",
                     events: opened + [report(.offset(ByteOffset(9)))],
                     phase: .transferring),
            Scenario(name: "everything confirmed",
                     events: opened + [report(everything)],
                     phase: .finalizing),
            Scenario(name: "finalized",
                     events: opened + [report(everything), .finalized],
                     phase: .completed),
            Scenario(name: "interrupted mid-transfer, authority silent",
                     events: opened + [.chunkTransferInterrupted(ChunkID(2))],
                     phase: .transferring),
            Scenario(name: "refused mid-transfer, authority silent",
                     events: opened + [.chunkTransferRefused(ChunkID(2))],
                     phase: .transferring),
            Scenario(name: "gave up with what the authority confirmed still on the log",
                     events: opened + [report(.chunks([ChunkID(1), ChunkID(2)])),
                                       .chunkTransferRefused(ChunkID(3)),
                                       report(.chunks([ChunkID(1), ChunkID(2)])),
                                       .abandoned(.retriesExhausted)],
                     phase: .failed),
            Scenario(name: "abandoned mid-transfer",
                     events: opened + [.abandoned(.taskCancelled)],
                     phase: .failed),
            Scenario(name: "premature finalize is rejected and does not stick",
                     events: opened + [.finalized, .chunkTransferReported(ChunkID(2))],
                     phase: .transferring),
            Scenario(name: "authority forgot what it had confirmed",
                     events: opened + [report(everything), report(.chunks([]))],
                     phase: .transferring),
            Scenario(name: "events after completion are absorbed",
                     events: opened + [report(everything), .finalized,
                                       .chunkTransferReported(ChunkID(1)),
                                       .abandoned(.taskCancelled),
                                       .declared(intent)],
                     phase: .completed),
        ]
    }

    /// State is a pure fold over the log and nothing else. Replaying a recorded sequence
    /// reproduces the state exactly; splitting the replay anywhere reproduces it too.
    ///
    /// The split is the point. A cold start replays from nothing, and it must land on the
    /// same state the running process held — otherwise recovery derives a different upload
    /// than the one that was actually in flight.
    func testEventLogReplayReproducesStateExactly_ForEveryRecordedSequence() async throws {
        for scenario in scenarios {
            let whole = UploadTransition.replay(scenario.events)

            XCTAssertEqual(whole.phase, scenario.phase,
                           "\(scenario.name): replay landed in the wrong phase")

            XCTAssertEqual(UploadTransition.replay(scenario.events), whole,
                           "\(scenario.name): replaying the same log twice gave two answers")

            for split in 0...scenario.events.count {
                let prefix = UploadTransition.replay(Array(scenario.events.prefix(split)))
                let resumed = UploadTransition.replay(Array(scenario.events.dropFirst(split)),
                                                      from: prefix)
                XCTAssertEqual(resumed, whole,
                               "\(scenario.name): splitting the replay at \(split) changed the result")
            }

            // Through the store and back: persistence must not alter the derivation.
            let log = InMemoryEventLog()
            try await log.append(scenario.events, for: upload)
            let recovered = UploadTransition.replay(try await log.records(for: upload).map(\.event))
            XCTAssertEqual(recovered, whole,
                           "\(scenario.name): a round trip through the log changed the state")
        }
    }
}
