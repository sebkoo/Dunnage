import XCTest
import DunnageCore
import DunnageLedger

/// The ledger on disk: the second implementation of `UploadEventLog`, and the first one
/// that outlives a process.
///
/// Every "cold start" here is a second `FileEventLog` over the same directory, which is all
/// a new process would have. No test in this file kills anything; see the honesty boundary
/// in ADR-0004.
final class FileEventLogTests: XCTestCase {

    // MARK: - The same contract the in-memory double keeps

    func testTheFileLedgerAppendsMonotonicallyAndNeverAltersEarlierRecords() async throws {
        try await EventLogContract.appendsMonotonicallyAndNeverAltersEarlierRecords(
            FileEventLog(directory: try temporaryDirectory()))
    }

    func testTheFileLedgerScopesSequencesToOneUpload() async throws {
        try await EventLogContract.sequencesAreScopedToOneUpload(
            FileEventLog(directory: try temporaryDirectory()))
    }

    func testTheFileLedgerEnumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot() async throws {
        try await EventLogContract.enumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot(
            FileEventLog(directory: try temporaryDirectory()))
    }

    // MARK: - What the disk is for

    /// The whole point of the phase. A process writes a log and stops existing; another one
    /// starts with nothing but the directory, and must derive the upload that was actually
    /// in flight rather than a different one.
    func testStateReplayedFromDiskIsTheStateTheWriterHeld() async throws {
        for scenario in RecordedLogs.all {
            let directory = try temporaryDirectory()

            let writer = FileEventLog(directory: directory)
            let written = try await writer.append(scenario.events, for: RecordedLogs.upload)
            let held = UploadTransition.replay(scenario.events)

            let coldStart = FileEventLog(directory: directory)
            let recovered = try await coldStart.records(for: RecordedLogs.upload)

            XCTAssertEqual(recovered, written,
                           "\(scenario.name): what came back off the disk is not what was written")
            XCTAssertEqual(recovered.map(\.sequence).map(\.value),
                           (0..<scenario.events.count).map { $0 + 1 },
                           "\(scenario.name): sequences from 1, without gaps, across the process boundary")
            XCTAssertEqual(UploadTransition.replay(recovered.map(\.event)), held,
                           "\(scenario.name): a cold start derived a different upload than the writer held")
            XCTAssertEqual(UploadTransition.replay(recovered.map(\.event)).phase, scenario.phase,
                           "\(scenario.name): and it landed in the wrong phase")
            let enumerated = try await coldStart.uploads()
            XCTAssertEqual(enumerated, [RecordedLogs.upload],
                           "\(scenario.name): a cold start could not find the upload it has to resume")
        }
    }

    /// Absent is the third way a file fails to be a log, and the protocol already says it is
    /// not an error: a cold start with nothing yet.
    func testAnAbsentLedgerIsAColdStartWithNothingYetAndNotAnError() async throws {
        let neverCreated = FileManager.default.temporaryDirectory
            .appendingPathComponent("dunnage-\(UUID().uuidString)", isDirectory: true)
        let missing = FileEventLog(directory: neverCreated)
        let noDirectory = try await missing.uploads()
        let noRecords = try await missing.records(for: RecordedLogs.upload)
        XCTAssertEqual(noDirectory, [], "a directory that was never created holds nothing")
        XCTAssertEqual(noRecords, [], "and asking it about an upload is not an error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: neverCreated.path),
                       "reading must not create the directory it was asked to read")

        let directory = try temporaryDirectory()
        let log = FileEventLog(directory: directory)
        let empty = try await log.uploads()
        XCTAssertEqual(empty, [], "an empty directory holds nothing either")

        try await log.append([.declared(RecordedLogs.intent)], for: RecordedLogs.upload)
        let neverDeclared = try await log.records(for: UploadID("never-declared"))
        XCTAssertEqual(neverDeclared, [],
                       "an upload this ledger has never seen has no records, and that is not an error")
    }

    /// The ledger file is named by the hex of the upload identifier, and the reason is the
    /// filesystem underneath. APFS is case-insensitive by default, so a case-sensitive
    /// encoding of the name can put two uploads in one file: base64url writes "man" as
    /// "bWFu" and "maT" as "bWFU", which differ only in the case of one character. Hex has
    /// no upper case to fold.
    func testUploadsThatACaseInsensitiveFilesystemCouldConfuseGetSeparateLedgers() async throws {
        let log = FileEventLog(directory: try temporaryDirectory())
        let man = UploadID("man")
        let maT = UploadID("maT")

        try await log.append([.declared(EventLogContract.intent(man))], for: man)
        try await log.append([.declared(EventLogContract.intent(maT)),
                              .transportSessionOpened(TransportSessionID("s"))], for: maT)

        let both = try await log.uploads()
        let forMan = try await log.records(for: man)
        let forMaT = try await log.records(for: maT)
        XCTAssertEqual(Set(both), [man, maT], "two uploads, two ledgers")
        XCTAssertEqual(forMan.count, 1)
        XCTAssertEqual(forMaT.count, 2,
                       "one upload's writes must not land in another upload's file")
        XCTAssertEqual(forMan.map(\.event), [.declared(EventLogContract.intent(man))])
    }

    /// A header naming a format this binary does not have is the same situation as an event
    /// it does not have, and gets the same answer. Reading it as version 1 would be a guess.
    func testALedgerWrittenInAFormatThisBinaryDoesNotKnowIsRefusedRatherThanRead() async throws {
        for (what, header) in [("a later version", "dunnage-ledger 2"),
                               ("not a ledger at all", "# upload log")] {
            let directory = try temporaryDirectory()
            let log = FileEventLog(directory: directory)
            try await log.append([.declared(RecordedLogs.intent)], for: RecordedLogs.upload)

            let file = try onlyLedgerFile(in: directory)
            let body = try Data(contentsOf: file).drop { $0 != UInt8(ascii: "\n") }
            try (Data(header.utf8) + body).write(to: file)

            let coldStart = FileEventLog(directory: directory)
            var refused = false
            do { _ = try await coldStart.records(for: RecordedLogs.upload) }
            catch { refused = true }
            XCTAssertTrue(refused, "\(what): was read rather than refused")

            var refusedTheAppend = false
            do { _ = try await coldStart.append([.finalized], for: RecordedLogs.upload) }
            catch { refusedTheAppend = true }
            XCTAssertTrue(refusedTheAppend,
                          "\(what): appending onto a log this binary cannot read leaves one neither can")
        }
    }

    /// ADR-0004 O-7. Enumeration reads the directory, and a `.ledger` file this module did
    /// not write is a file it cannot say anything about. Stepping over it would leave a cold
    /// start enumerating some of what is outstanding and reporting that as all of it.
    func testAFileInTheLedgerDirectoryThisModuleDidNotWriteIsRefusedRatherThanIgnored() async throws {
        let directory = try temporaryDirectory()
        let log = FileEventLog(directory: directory)
        try await log.append([.declared(RecordedLogs.intent)], for: RecordedLogs.upload)

        // Not hex, so not a name this module produces, whatever else it may be.
        try Data().write(to: directory.appendingPathComponent("notes.ledger"))

        var refusal: Error?
        do { _ = try await log.uploads() } catch { refusal = error }
        XCTAssertEqual(refusal as? LedgerError, .unrecognizedLedgerFile(name: "notes.ledger"),
                       "a ledger file this module did not write was enumerated as if it had")

        // A file that is not a ledger at all is not this module's business either way.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("notes.ledger"))
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        let found = try await log.uploads()
        XCTAssertEqual(found, [RecordedLogs.upload],
                       "a file that does not claim to be a ledger is not one")
    }

    /// The name is derived from the identifier and never shortened or hashed to fit.
    /// Shortening two identifiers into one name would put two uploads in one file, which is
    /// the failure the hex encoding exists to prevent, arriving by a different road.
    func testAnUploadIdentifierTooLongToNameAFileIsRefusedRatherThanShortened() async throws {
        let log = FileEventLog(directory: try temporaryDirectory())

        let long = UploadID(String(repeating: "u", count: 100))
        try await log.append([.declared(EventLogContract.intent(long))], for: long)
        let held = try await log.records(for: long)
        XCTAssertEqual(held.count, 1, "an identifier that fits is not the interesting case")

        let tooLong = UploadID(String(repeating: "u", count: 200))
        var refusal: Error?
        do { _ = try await log.append([.declared(EventLogContract.intent(tooLong))], for: tooLong) }
        catch { refusal = error }
        XCTAssertEqual(refusal as? LedgerError, .uploadIdentifierTooLongForAFilename(tooLong),
                       "an identifier that does not fit was written somewhere it does")
    }

    // MARK: -

    private func onlyLedgerFile(in directory: URL) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".ledger") }
        XCTAssertEqual(names.count, 1, "expected exactly one ledger file")
        return directory.appendingPathComponent(names[0])
    }
}
