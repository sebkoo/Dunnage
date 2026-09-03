import XCTest
import DunnageCore

/// The contract every `UploadEventLog` owes, written once and held against every
/// implementation there is.
///
/// It lives here rather than inside one test class because there are now two
/// implementations — an in-memory double and a file on disk — and a contract that only one
/// of them is measured against is a description of that one, not a contract.
enum EventLogContract {

    static let uploadA = UploadID("upload-a")
    static let uploadB = UploadID("upload-b")

    static func intent(_ upload: UploadID) -> UploadIntent {
        UploadIntent(upload: upload,
                     destination: DestinationRef("destination-\(upload.rawValue)"),
                     payload: PayloadRef("payload-a"),
                     plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    }

    static func appendsMonotonicallyAndNeverAltersEarlierRecords(
        _ log: some UploadEventLog, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let first = try await log.append(
            [.declared(intent(uploadA)), .transportSessionOpened(TransportSessionID("s1"))],
            for: uploadA)
        XCTAssertEqual(first.map(\.sequence), [LogSequence(1), LogSequence(2)],
                       "a log assigns sequences from 1, without gaps", file: file, line: line)

        let second = try await log.append([.chunkTransferReported(ChunkID(1))], for: uploadA)
        XCTAssertEqual(second.map(\.sequence), [LogSequence(3)],
                       "a later append continues the sequence rather than restarting it",
                       file: file, line: line)

        let all = try await log.records(for: uploadA)
        XCTAssertEqual(all.map(\.sequence), [LogSequence(1), LogSequence(2), LogSequence(3)],
                       file: file, line: line)
        XCTAssertEqual(all.map(\.event),
                       [.declared(intent(uploadA)),
                        .transportSessionOpened(TransportSessionID("s1")),
                        .chunkTransferReported(ChunkID(1))],
                       "records come back in append order, unchanged", file: file, line: line)
        XCTAssertEqual(Array(all.prefix(2)), first,
                       "appending must not alter records already written", file: file, line: line)
    }

    static func sequencesAreScopedToOneUpload(
        _ log: some UploadEventLog, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await log.append([.declared(intent(uploadA))], for: uploadA)
        let b = try await log.append([.declared(intent(uploadB))], for: uploadB)

        XCTAssertEqual(b.map(\.sequence), [LogSequence(1)],
                       "one upload's log does not advance because another was written",
                       file: file, line: line)
        let recordsA = try await log.records(for: uploadA)
        let recordsB = try await log.records(for: uploadB)
        XCTAssertEqual(recordsA.count, 1, file: file, line: line)
        XCTAssertEqual(recordsB.count, 1, file: file, line: line)
    }

    static func enumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot(
        _ log: some UploadEventLog, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let freshUploads = try await log.uploads()
        let unknownRecords = try await log.records(for: uploadA)
        XCTAssertEqual(freshUploads, [], "a fresh log holds nothing", file: file, line: line)
        XCTAssertEqual(unknownRecords, [],
                       "an unknown upload has no records, and that is not an error",
                       file: file, line: line)

        try await log.append([.declared(intent(uploadA))], for: uploadA)
        try await log.append([.declared(intent(uploadB))], for: uploadB)
        try await log.append([.finalized], for: uploadA)

        let known = try await log.uploads()
        XCTAssertEqual(Set(known), [uploadA, uploadB],
                       "a cold start must be able to enumerate what is outstanding",
                       file: file, line: line)
        XCTAssertEqual(known.count, 2, "an upload is enumerated once, not per append",
                       file: file, line: line)
    }
}
