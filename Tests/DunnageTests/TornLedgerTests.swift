import XCTest
import DunnageCore
import DunnageLedger

/// A file that exists is not a log.
///
/// Every file here is constructed byte by byte and every assertion is about what replay does
/// with it. Nothing in this file kills a process, and nothing here is evidence that a
/// process death produces such a file: that is a lifecycle claim, it belongs to the device
/// harness, and ADR-0004 says so where a reader will find it.
final class TornLedgerTests: XCTestCase {

    private let upload = RecordedLogs.upload
    private let session = RecordedLogs.session

    /// The two records that were whole before the write that did not finish.
    private var whole: [UploadEvent] {
        [.declared(RecordedLogs.intent), .transportSessionOpened(session)]
    }

    /// The one that was still being written. It confirms chunks 1 and 2, so a reader that
    /// takes it for an event stops sending them.
    private var interrupted: UploadEvent {
        RecordedLogs.report(.chunks([ChunkID(1), ChunkID(2)]))
    }

    /// Reading stops *before* the incomplete record, not at it. The bytes end in the middle
    /// of an event, so no event was durably recorded there, and deriving one from them would
    /// claim the authority confirmed chunks it never answered about.
    func testATornTailIsNotAnEventAndReplayStopsBeforeIt() async throws {
        // Every depth of tear: one byte short, most of the record gone, and short enough
        // that even the length in front of the payload is incomplete.
        for takenBack in [1, 4, 20, 41, 44] {
            let directory = try temporaryDirectory()
            let log = FileEventLog(directory: directory)
            try await log.append(whole, for: upload)
            guard try await tearBack(takenBack, afterWriting: interrupted,
                                     to: directory, for: upload) else { continue }

            let coldStart = FileEventLog(directory: directory)
            let records = try await coldStart.records(for: upload)

            XCTAssertEqual(records.map(\.event), whole,
                           "\(takenBack) bytes short: the torn tail was read as an event")
            XCTAssertEqual(records.map(\.sequence), [LogSequence(1), LogSequence(2)],
                           "\(takenBack) bytes short: a record that never finished has no position")

            let derived = UploadTransition.replay(records.map(\.event))
            XCTAssertEqual(derived, UploadTransition.replay(whole),
                           "\(takenBack) bytes short: replay derived a state the log does not hold")

            guard case .transferring(let intent, _, let confirmed, _) = derived else {
                return XCTFail("\(takenBack) bytes short: expected a transfer in flight")
            }
            XCTAssertNil(confirmed,
                         "\(takenBack) bytes short: the authority never answered, so nothing is confirmed")
            XCTAssertEqual(ResumePlan.derive(for: intent, given: confirmed).transfers.map(\.chunk),
                           intent.plan.chunks,
                           "\(takenBack) bytes short: a chunk was skipped that nobody confirmed")
        }
    }

    /// The writer needs the marker too. Appending past bytes that are not a record would
    /// leave them in the middle of the file, where a reader that stops at the first
    /// incomplete frame never reaches anything after them.
    ///
    /// The only bytes removed are bytes that are not a record. No event is dropped, because
    /// no event was ever there.
    func testAppendingAfterATornTailReplacesTheTornBytesRatherThanWritingPastThem() async throws {
        let directory = try temporaryDirectory()
        let log = FileEventLog(directory: directory)
        try await log.append(whole, for: upload)
        let tore = try await tearBack(6, afterWriting: interrupted, to: directory, for: upload)
        XCTAssertTrue(tore)

        let afterTheTear = FileEventLog(directory: directory)
        let appended = try await afterTheTear.append([.chunkTransferReported(ChunkID(1))], for: upload)
        XCTAssertEqual(appended.map(\.sequence), [LogSequence(3)],
                       "the position the unfinished write did not take is free")

        let records = try await FileEventLog(directory: directory).records(for: upload)
        XCTAssertEqual(records.map(\.event), whole + [.chunkTransferReported(ChunkID(1))],
                       "the record written after the tear is unreachable, or the tear is still there")
        XCTAssertEqual(records.map(\.sequence), [LogSequence(1), LogSequence(2), LogSequence(3)])

        // And the file is a log again: it takes another append and reads back whole.
        try await afterTheTear.append([.finalized], for: upload)
        let andAgain = try await FileEventLog(directory: directory).records(for: upload)
        XCTAssertEqual(andAgain.count, 4, "the ledger did not recover into a writable state")
    }

    /// The three ways a file fails to be a log are three answers. Collapsing any two of
    /// them is the bug: an absent log and a torn one both look like "fewer records", and a
    /// record from a newer build looks like neither.
    func testTornUnknownAndAbsentAreThreeAnswersAndNeverOne() async throws {
        let absent = FileEventLog(directory: try temporaryDirectory())
        let fromAbsent = try await absent.records(for: upload)
        XCTAssertEqual(fromAbsent, [], "absent: nothing yet, and not an error")

        let tornDirectory = try temporaryDirectory()
        let torn = FileEventLog(directory: tornDirectory)
        try await torn.append(whole, for: upload)
        let toreIt = try await tearBack(6, afterWriting: interrupted, to: tornDirectory, for: upload)
        XCTAssertTrue(toreIt)
        let fromTorn = try await FileEventLog(directory: tornDirectory).records(for: upload)
        XCTAssertEqual(fromTorn.map(\.event), whole,
                       "torn: the records that were whole, and not an error")

        let unknownDirectory = try temporaryDirectory()
        let unknown = FileEventLog(directory: unknownDirectory)
        try await unknown.append(whole, for: upload)
        try appendRawRecord(#"{"chunk":2,"event":"chunkTransferDisavowed"}"#, to: unknownDirectory)

        var refusal: Error?
        do { _ = try await FileEventLog(directory: unknownDirectory).records(for: upload) }
        catch { refusal = error }
        XCTAssertEqual(refusal as? LedgerError,
                       .unreadableRecord(upload: upload, sequence: LogSequence(3),
                                         fault: .unknownToken(field: "event",
                                                              token: "chunkTransferDisavowed")),
                       "unknown: a complete record a newer build wrote is refused, by position and by name")

        XCTAssertNotEqual(fromAbsent, fromTorn, "absent and torn are not the same answer")
        XCTAssertNotNil(refusal, "and neither of them is what an unrecognised record gets")
    }

    /// A truncation is a short prefix. If the payload's bytes were all present and the
    /// terminator is not a newline, nothing was truncated here — so this is not a tear, and
    /// trimming it would discard bytes that something did finish writing.
    func testBytesThatWereAllThereAreNotATearAndAreRefusedRatherThanTrimmed() async throws {
        let directory = try temporaryDirectory()
        let log = FileEventLog(directory: directory)
        try await log.append(whole + [interrupted], for: upload)

        let file = try onlyLedgerFile(in: directory)
        var bytes = [UInt8](try Data(contentsOf: file))
        bytes[bytes.count - 1] = UInt8(ascii: "!")          // the terminator, and only it
        try Data(bytes).write(to: file)

        var refused = false
        do { _ = try await FileEventLog(directory: directory).records(for: upload) }
        catch { refused = true }
        XCTAssertTrue(refused, "a frame that is present and is not a frame was read as a tear")
    }

    // MARK: - Constructing the file

    /// Write `event` and then take the last `bytes` of it back, leaving a record that ends
    /// before it is whole. Returns false when the record is shorter than that, so a depth
    /// that would eat into the records before it is skipped rather than silently testing
    /// something else.
    @discardableResult
    private func tearBack(_ bytes: Int, afterWriting event: UploadEvent,
                          to directory: URL, for upload: UploadID) async throws -> Bool {
        let file = try onlyLedgerFile(in: directory)
        let before = try Data(contentsOf: file).count
        try await FileEventLog(directory: directory).append([event], for: upload)
        let after = try Data(contentsOf: file).count
        guard after - before > bytes else { return false }

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(after - bytes))
        return true
    }

    /// A whole record, framed by hand. The framing rule is written out here rather than
    /// borrowed from the module, so that this test would notice the module changing it.
    private func appendRawRecord(_ payload: String, to directory: URL) throws {
        let file = try onlyLedgerFile(in: directory)
        let frame = "\(payload.utf8.count) \(payload)\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(frame.utf8))
    }

    private func onlyLedgerFile(in directory: URL) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".ledger") }
        XCTAssertEqual(names.count, 1, "expected exactly one ledger file")
        return directory.appendingPathComponent(names[0])
    }
}
