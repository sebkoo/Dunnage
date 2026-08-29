import XCTest
import DunnageCore

final class ChunkPlanTests: XCTestCase {

    /// Every byte of the declared payload belongs to exactly one chunk.
    ///
    /// A gap silently drops bytes. An overlap makes "this chunk is confirmed" ambiguous
    /// about *which* bytes are confirmed, which is the one thing the thesis cannot
    /// tolerate: the whole bound rests on a chunk naming a fixed span.
    func testChunkPlanPartitionsThePayloadExactlyOnce() {
        for totalBytes in 0...64 {
            for chunkSize in 1...9 {
                let plan = ChunkPlan(totalBytes: totalBytes, chunkSize: chunkSize)
                let context = "totalBytes=\(totalBytes) chunkSize=\(chunkSize)"

                var cursor = 0
                for chunk in plan.chunks {
                    guard let range = plan.range(of: chunk) else {
                        return XCTFail("\(context): \(chunk) is in the plan but has no range")
                    }
                    XCTAssertEqual(range.start.value, cursor,
                                   "\(context): \(chunk) does not start where the previous chunk ended")
                    XCTAssertFalse(range.isEmpty, "\(context): \(chunk) covers no bytes")
                    XCTAssertLessThanOrEqual(range.count, chunkSize,
                                             "\(context): \(chunk) is larger than the chunk size")
                    cursor = range.endExclusive.value
                }

                XCTAssertEqual(cursor, totalBytes,
                               "\(context): the plan's chunks do not cover the whole payload")
                XCTAssertEqual(plan.chunks.count, plan.chunkCount,
                               "\(context): chunkCount disagrees with the chunks it enumerates")
            }
        }
    }

    /// An ordinal outside the plan has no range at all, which is a different answer from
    /// an empty range. Collapsing the two would let a confirmation naming a chunk this
    /// upload never planned resolve to a well-formed span of zero bytes.
    func testChunkPlanHasNoRangeForAnOrdinalOutsideThePlan() {
        let plan = ChunkPlan(totalBytes: 10, chunkSize: 4)
        XCTAssertEqual(plan.chunkCount, 3)
        XCTAssertNotNil(plan.range(of: ChunkID(3)), "chunk 3 is the last chunk of this plan")
        XCTAssertNil(plan.range(of: ChunkID(4)), "chunk 4 is past the end of this plan")
        XCTAssertNil(plan.range(of: ChunkID(9_999)), "chunk 9999 is far past the end of this plan")
    }
}
