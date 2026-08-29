import XCTest
import DunnageCore

final class ReplayTests: XCTestCase {

    /// State is a pure fold over the log and nothing else. Replaying a recorded sequence
    /// reproduces the state exactly; splitting the replay anywhere reproduces it too.
    ///
    /// The split is the point. A cold start replays from nothing, and it must land on the
    /// same state the running process held — otherwise recovery derives a different upload
    /// than the one that was actually in flight.
    func testEventLogReplayReproducesStateExactly_ForEveryRecordedSequence() async throws {
        for scenario in RecordedLogs.all {
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
            try await log.append(scenario.events, for: RecordedLogs.upload)
            let recovered = UploadTransition.replay(try await log.records(for: RecordedLogs.upload).map(\.event))
            XCTAssertEqual(recovered, whole,
                           "\(scenario.name): a round trip through the log changed the state")
        }
    }
}
