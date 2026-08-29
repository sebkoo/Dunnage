import XCTest
import DunnageCore

final class ConfirmedProgressTests: XCTestCase {

    // chunk 1 = [0,4)   chunk 2 = [4,8)   chunk 3 = [8,10)
    private let plan = ChunkPlan(totalBytes: 10, chunkSize: 4)

    /// Set-shaped authority is taken at its word: the confirmed chunks are the ones it
    /// names, with no contiguity read into them. An authority holding 1, 2 and 4 has said
    /// nothing whatsoever about 3.
    func testSetShapedAuthorityConfirmsExactlyTheChunksItNames() {
        let plan = ChunkPlan(totalBytes: 20, chunkSize: 4)   // chunks 1...5
        let held: Set<ChunkID> = [ChunkID(1), ChunkID(2), ChunkID(4)]

        XCTAssertEqual(ConfirmedProgress.chunks(held).confirmedChunks(in: plan), held,
                       "a set-shaped authority's confirmed set is the set it reported")
        XCTAssertEqual(ConfirmedProgress.chunks([]).confirmedChunks(in: plan), [],
                       "an authority holding nothing confirms nothing")
    }

    /// An id this plan does not contain is not confirmable against this plan. Passing it
    /// through would let an authority's report widen to chunks the upload never declared.
    func testAuthorityReportingAChunkOutsideThePlanConfirmsNothingExtra() {
        let reported: Set<ChunkID> = [ChunkID(1), ChunkID(99)]
        XCTAssertEqual(ConfirmedProgress.chunks(reported).confirmedChunks(in: plan),
                       [ChunkID(1)],
                       "chunk 99 is not in a three-chunk plan and cannot be confirmed by it")
    }

    /// Offset-shaped authority guarantees a contiguous prefix. A chunk is confirmed only if
    /// its whole range lies below the offset; a chunk the offset falls inside is partially
    /// transferred, which is not confirmed at all.
    ///
    /// Rounding the offset up to the next chunk boundary would mark bytes confirmed that
    /// the authority never claimed, and those bytes would then never be sent again.
    func testOffsetShapedAuthorityConfirmsOnlyChunksWhollyBelowTheOffset() {
        let expected: [(Int, Set<ChunkID>)] = [
            (0,  []),
            (1,  []),                                        // inside chunk 1
            (3,  []),                                        // still inside chunk 1
            (4,  [ChunkID(1)]),                              // chunk 1 exactly complete
            (5,  [ChunkID(1)]),                              // inside chunk 2
            (7,  [ChunkID(1)]),                              // still inside chunk 2
            (8,  [ChunkID(1), ChunkID(2)]),                  // chunk 2 exactly complete
            (9,  [ChunkID(1), ChunkID(2)]),                  // inside the short last chunk
            (10, [ChunkID(1), ChunkID(2), ChunkID(3)]),      // whole payload
        ]

        for (offset, want) in expected {
            let got = ConfirmedProgress.offset(ByteOffset(offset)).confirmedChunks(in: plan)
            XCTAssertEqual(got, want, "offset \(offset) confirmed the wrong chunks")
        }
    }
}
