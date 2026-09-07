import XCTest
import DunnageCore
@testable import Dunnage

/// Tier 1 (ADR-0007 §2): no session, no socket, no clock. The screen is derived from the log
/// by one pure function, and this is that function on its own.
final class UploadModelStatusTests: XCTestCase {

    // chunks 1...3, four bytes each
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        payload: PayloadRef("payload-a"),
        plan: ChunkPlan(totalBytes: 12, chunkSize: 4))
    private let dead = TransportSessionID("session-1")
    private let live = TransportSessionID("session-2")

    /// ADR-0009 §3, one layer out from the transition table.
    ///
    /// `reported` is what a completion said since the authority last spoke — an observation
    /// about a request, scoped to the transport operation that made it. It is weaker evidence
    /// than a confirmation, and the confirmation does not survive the operation it was scoped
    /// to, so this cannot either. A screen that kept it would show a dead operation's chunks
    /// as reported while the replacement's authority has been asked nothing and holds
    /// nothing, which is the word phase 1 keeps apart from confirmed standing where a reader
    /// takes it for progress.
    @MainActor
    func testTheScreenDropsWhatADeadOperationReportedWhenTheOperationIsReplaced() {
        let reported: [UploadEvent] = [
            .declared(intent), .transportSessionOpened(dead),
            .chunkTransferReported(ChunkID(1)), .chunkTransferReported(ChunkID(2)),
        ]

        // The contrast first, so the drop below is shown to do something rather than
        // asserted: against this log the two chunks are reported and the third is not.
        let before = UploadModel.statuses(of: intent,
                                          given: UploadTransition.replay(reported),
                                          events: reported, inFlight: [])
        XCTAssertEqual(before[ChunkID(1)], .reported, "the log above reports chunk 1")
        XCTAssertEqual(before[ChunkID(2)], .reported, "the log above reports chunk 2")
        XCTAssertEqual(before[ChunkID(3)], .planned, "and says nothing about chunk 3")

        let replaced = reported + [.transportSessionLost(dead), .transportSessionOpened(live)]
        let after = UploadModel.statuses(of: intent,
                                         given: UploadTransition.replay(replaced),
                                         events: replaced, inFlight: [])
        for chunk in intent.plan.chunks {
            XCTAssertEqual(after[chunk], .planned,
                           "chunk \(chunk.ordinal): a report the dead operation made is not evidence about the replacement")
        }
    }
}
