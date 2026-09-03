import XCTest
import DunnageCore
import DunnageTransport

/// A chunk file is a cache bounded by the in-flight set.
///
/// ADR-0007 §7: a chunk file is written at `send` from `PayloadRef` and the plan's range,
/// deleted when the authority confirms the chunk, and deleting any of them is always safe
/// because the next `send` re-derives it. Nothing here touches a session; the payload is a
/// file in a temporary directory, and the `PayloadRef` resolves to it.
final class ChunkFilesTests: XCTestCase {

    private let ref = PayloadRef("payloads/abc")

    /// A payload of `count` bytes, byte `i` holding the value `i`, and a `ChunkFiles` whose
    /// resolver finds it. Nothing about the layout depends on where the directory is.
    private func payload(of count: Int, chunkSize: Int) throws -> (ChunkFiles, UploadIntent) {
        let root = try temporaryDirectory()
        let support = root.appendingPathComponent("support", isDirectory: true)
        let file = support.appendingPathComponent(ref.rawValue)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<count).map { UInt8($0) }).write(to: file)

        let intent = UploadIntent(upload: UploadID("upload-a"),
                                  destination: DestinationRef("destination-a"),
                                  payload: ref,
                                  plan: ChunkPlan(totalBytes: count, chunkSize: chunkSize))
        let files = ChunkFiles(directory: root.appendingPathComponent("chunks", isDirectory: true),
                               resolve: { support.appendingPathComponent($0.rawValue) })
        return (files, intent)
    }

    private func transfer(_ ordinal: Int, of intent: UploadIntent) -> PlannedTransfer {
        let chunk = ChunkID(ordinal)
        return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
    }

    /// Chunk 2 of a 12-byte payload cut in fours is bytes 4 through 7, and the trailing
    /// chunk of a 10-byte payload is the two bytes that are left — not four, not a
    /// zero-padded four.
    func testAChunkFileHoldsExactlyTheSpanThePlanNames() throws {
        let cases: [(bytes: Int, chunk: Int, expected: [UInt8])] = [
            (12, 2, [4, 5, 6, 7]),
            (10, 3, [8, 9]),
        ]
        for c in cases {
            let context = "\(c.bytes) bytes, chunk \(c.chunk)"
            do {
                let (files, intent) = try payload(of: c.bytes, chunkSize: 4)
                let url = try files.file(for: transfer(c.chunk, of: intent), of: intent)
                XCTAssertEqual([UInt8](try Data(contentsOf: url)), c.expected,
                               "\(context): the chunk file is not the span the plan names")
            } catch {
                XCTFail("\(context): \(error)")
            }
        }
    }

    /// A plan made against 12 bytes, and a payload that has 10: chunk 3 names bytes 8
    /// through 11, and only two of them exist. A chunk file written short would be sent as
    /// if it were whole, so the span is refused with what was expected and what was read,
    /// and no file for the chunk is left behind.
    func testAPayloadShorterThanThePlanIsRefusedRatherThanWrittenShort() throws {
        let (files, tenBytes) = try payload(of: 10, chunkSize: 4)
        let intent = UploadIntent(upload: tenBytes.upload,
                                  destination: tenBytes.destination,
                                  payload: tenBytes.payload,
                                  plan: ChunkPlan(totalBytes: 12, chunkSize: 4))

        var refused: ChunkFiles.Failure?
        do { _ = try files.file(for: transfer(3, of: intent), of: intent) }
        catch let failure as ChunkFiles.Failure { refused = failure }
        XCTAssertEqual(refused,
                       .payloadShorterThanThePlan(ref, ChunkID(3), expected: 4, read: 2),
                       "a short span was written as a chunk, or refused without saying how short")
        XCTAssertEqual(try files.present(for: intent.upload), [],
                       "a refused chunk left a file behind")
    }

    /// Three chunk files written, two confirmed and discarded: one remains. Discarding a
    /// chunk already gone is not an error, because a confirmation can arrive for a chunk
    /// whose file was never written by this process. Removing the upload leaves nothing.
    func testTheChunkFilesThatExistAtOnceAreBoundedByTheInFlightSet() throws {
        let (files, intent) = try payload(of: 12, chunkSize: 4)
        for ordinal in 1...3 {
            _ = try files.file(for: transfer(ordinal, of: intent), of: intent)
        }
        XCTAssertEqual(try files.present(for: intent.upload), [ChunkID(1), ChunkID(2), ChunkID(3)])

        try files.discard([ChunkID(1), ChunkID(2)], of: intent.upload)
        XCTAssertEqual(try files.present(for: intent.upload), [ChunkID(3)],
                       "a confirmed chunk's file is gone, and an unconfirmed one's is not")

        XCTAssertNoThrow(try files.discard([ChunkID(2)], of: intent.upload),
                         "discarding a chunk file that is already gone is not an error")
        XCTAssertEqual(try files.present(for: intent.upload), [ChunkID(3)])

        try files.remove(intent.upload)
        XCTAssertEqual(try files.present(for: intent.upload), [],
                       "removing the upload leaves no chunk file behind")
    }
}
