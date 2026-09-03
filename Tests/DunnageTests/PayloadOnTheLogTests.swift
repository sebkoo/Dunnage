import XCTest
import DunnageCore
import DunnageLedger

/// A cold start finds the payload on the log.
///
/// ADR-0006 O-12 found the gap: a relaunched process had the intent's destination and plan
/// on the log and no way to find the bytes. ADR-0007 §8 closes it by carrying `PayloadRef`
/// on the intent, so the declaration on disk is the whole intent, payload included. The
/// "cold start" here is a second `FileEventLog` over the same directory, which is all a
/// new process would have; nothing in this file kills anything.
final class PayloadOnTheLogTests: XCTestCase {

    func testAColdStartFindsThePayloadOnTheLog() async throws {
        let directory = try temporaryDirectory()
        let intent = UploadIntent(upload: UploadID("upload-a"),
                                  destination: DestinationRef("destination-a"),
                                  payload: PayloadRef("payloads/abc"),
                                  plan: ChunkPlan(totalBytes: 20, chunkSize: 4))

        let writer = FileEventLog(directory: directory)
        try await writer.append([.declared(intent)], for: intent.upload)

        let coldStart = FileEventLog(directory: directory)
        let records = try await coldStart.records(for: intent.upload)
        let state = UploadTransition.replay(records.map(\.event))

        guard case .declared(intent: let found) = state else {
            return XCTFail("replaying one declaration derives .declared, not \(state)")
        }
        XCTAssertEqual(found.payload, PayloadRef("payloads/abc"),
                       "the payload a cold start finds is the one that was declared")
    }
}
