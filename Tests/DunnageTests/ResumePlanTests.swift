import XCTest
import DunnageCore

final class ResumePlanTests: XCTestCase {

    // chunks 1...5, each 4 bytes: [0,4) [4,8) [8,12) [12,16) [16,20)
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        payload: PayloadRef("payload-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))

    private func scheduled(_ confirmed: ConfirmedProgress?) -> Set<ChunkID> {
        Set(ResumePlan.derive(for: intent, given: confirmed).transfers.map(\.chunk))
    }

    /// The thesis, stated as a test. Once the authority has positively confirmed a chunk,
    /// that chunk is never handed to a transport again — under either confirmation shape,
    /// since the thesis is not allowed to depend on which contract is in play.
    func testAuthorityConfirmedChunk_IsNeverRescheduled() {
        let all = Set(intent.plan.chunks)

        // Every possible set-shaped report over a five-chunk plan.
        for mask in 0..<32 {
            let held = Set((1...5).filter { mask & (1 << ($0 - 1)) != 0 }.map(ChunkID.init))
            let got = scheduled(.chunks(held))
            XCTAssertTrue(got.isDisjoint(with: held),
                          "held=\(held.sorted { $0.ordinal < $1.ordinal }): rescheduled a confirmed chunk")
            XCTAssertEqual(got.union(held), all,
                           "held=\(held.sorted { $0.ordinal < $1.ordinal }): an unconfirmed chunk was dropped")
        }

        // Every possible offset-shaped report over the same plan.
        for offset in 0...20 {
            let confirmed = ConfirmedProgress.offset(ByteOffset(offset))
            let held = confirmed.confirmedChunks(in: intent.plan)
            let got = scheduled(confirmed)
            XCTAssertTrue(got.isDisjoint(with: held),
                          "offset \(offset): rescheduled a confirmed chunk")
            XCTAssertEqual(got.union(held), all,
                           "offset \(offset): an unconfirmed chunk was dropped")
        }
    }

    /// Before the authority has been asked, nothing is confirmed and everything is
    /// scheduled. Core plans from what the authority has said, and it has said nothing —
    /// never from the bytes some transport was previously handed.
    func testAnUploadWithNoAuthorityReportYetSchedulesEveryChunk() {
        let plan = ResumePlan.derive(for: intent, given: nil)
        XCTAssertEqual(plan.transfers.map(\.chunk), intent.plan.chunks,
                       "with no confirmation on record, every chunk is still outstanding")
    }

    /// A set-shaped authority reports a set, not a frontier. Holding 1, 2 and 4 says
    /// nothing about 3, so resume schedules exactly 3 and 5.
    ///
    /// This is the test a naive implementation fails: anything that resumes from "the
    /// highest confirmed chunk" schedules 5 alone and loses chunk 3, and anything that
    /// resumes from "the first gap" schedules 3, 4 and 5 and re-sends a confirmed chunk.
    func testAuthorityReportsNonContiguousParts_ResumeSchedulesOnlyMissingParts() {
        let held: Set<ChunkID> = [ChunkID(1), ChunkID(2), ChunkID(4)]
        let plan = ResumePlan.derive(for: intent, given: .chunks(held))

        XCTAssertEqual(plan.transfers.map(\.chunk), [ChunkID(3), ChunkID(5)],
                       "resume must schedule exactly the missing chunks, in order")
        XCTAssertEqual(plan.transfers.map(\.range),
                       [ByteRange(start: ByteOffset(8), endExclusive: ByteOffset(12)),
                        ByteRange(start: ByteOffset(16), endExclusive: ByteOffset(20))],
                       "each missing chunk is scheduled over its whole range")
    }

    /// An offset-shaped authority's prefix can end inside a chunk. That chunk is not
    /// confirmed, but the bytes below the offset are — so only the suffix is scheduled.
    func testOffsetShapedResumeSendsOnlyTheUnconfirmedSuffixOfAPartialChunk() {
        let plan = ResumePlan.derive(for: intent, given: .offset(ByteOffset(10)))

        XCTAssertEqual(plan.transfers.first?.chunk, ChunkID(3),
                       "chunk 3 holds byte 10 and is only partly transferred")
        XCTAssertEqual(plan.transfers.first?.range,
                       ByteRange(start: ByteOffset(10), endExclusive: ByteOffset(12)),
                       "only bytes 10..<12 of chunk 3 are still unconfirmed")
        XCTAssertEqual(plan.transfers.dropFirst().map(\.range),
                       [ByteRange(start: ByteOffset(12), endExclusive: ByteOffset(16)),
                        ByteRange(start: ByteOffset(16), endExclusive: ByteOffset(20))],
                       "chunks beyond the offset are scheduled whole")
    }
}
