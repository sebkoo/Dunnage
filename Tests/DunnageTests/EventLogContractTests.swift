import XCTest
import DunnageCore

/// The contract every `UploadEventLog` owes, exercised against the in-memory double.
/// A fake that does not keep this contract makes every test built on it meaningless.
final class EventLogContractTests: XCTestCase {

    private let uploadA = UploadID("upload-a")
    private let uploadB = UploadID("upload-b")

    private func intent(_ upload: UploadID) -> UploadIntent {
        UploadIntent(upload: upload,
                     destination: DestinationRef("destination-\(upload.rawValue)"),
                     plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    }

    func testEventLogStoreAppendsMonotonicallyAndNeverAltersEarlierRecords() async throws {
        let log = InMemoryEventLog()

        let first = try await log.append(
            [.declared(intent(uploadA)), .transportSessionOpened(TransportSessionID("s1"))],
            for: uploadA)
        XCTAssertEqual(first.map(\.sequence), [LogSequence(1), LogSequence(2)],
                       "a log assigns sequences from 1, without gaps")

        let second = try await log.append([.chunkTransferReported(ChunkID(1))], for: uploadA)
        XCTAssertEqual(second.map(\.sequence), [LogSequence(3)],
                       "a later append continues the sequence rather than restarting it")

        let all = try await log.records(for: uploadA)
        XCTAssertEqual(all.map(\.sequence), [LogSequence(1), LogSequence(2), LogSequence(3)])
        XCTAssertEqual(all.map(\.event),
                       [.declared(intent(uploadA)),
                        .transportSessionOpened(TransportSessionID("s1")),
                        .chunkTransferReported(ChunkID(1))],
                       "records come back in append order, unchanged")
        XCTAssertEqual(Array(all.prefix(2)), first,
                       "appending must not alter records already written")
    }

    func testEventLogSequencesAreScopedToOneUpload() async throws {
        let log = InMemoryEventLog()
        try await log.append([.declared(intent(uploadA))], for: uploadA)
        let b = try await log.append([.declared(intent(uploadB))], for: uploadB)

        XCTAssertEqual(b.map(\.sequence), [LogSequence(1)],
                       "one upload's log does not advance because another was written")
        let recordsA = try await log.records(for: uploadA)
        let recordsB = try await log.records(for: uploadB)
        XCTAssertEqual(recordsA.count, 1)
        XCTAssertEqual(recordsB.count, 1)
    }

    func testEventLogEnumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot() async throws {
        let log = InMemoryEventLog()
        let freshUploads = try await log.uploads()
        let unknownRecords = try await log.records(for: uploadA)
        XCTAssertEqual(freshUploads, [], "a fresh log holds nothing")
        XCTAssertEqual(unknownRecords, [],
                       "an unknown upload has no records, and that is not an error")

        try await log.append([.declared(intent(uploadA))], for: uploadA)
        try await log.append([.declared(intent(uploadB))], for: uploadB)
        try await log.append([.finalized], for: uploadA)

        let known = try await log.uploads()
        XCTAssertEqual(Set(known), [uploadA, uploadB],
                       "a cold start must be able to enumerate what is outstanding")
        XCTAssertEqual(known.count, 2, "an upload is enumerated once, not per append")
    }
}
