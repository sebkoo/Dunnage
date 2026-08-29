import XCTest
import DunnageCore
import DunnageLedger

/// The negative control for phase 2.
///
/// Phase 1 has its own, and it is a different failure: a transport whose authority cannot
/// name a unit loses every byte it was holding. This one is the thesis failing from the
/// other end. Not re-sending bytes that were confirmed, but *skipping* bytes that were not —
/// a torn tail read as an event, deriving progress nobody ever gave.
///
/// It is never "fixed". If `MarkerlessEventLog` ever stops losing this, the control has been
/// broken and the framed ledger has nothing left to be measured against.
final class LedgerNegativeControlTests: XCTestCase {

    // twenty chunks of four bytes
    private let intent = UploadIntent(upload: UploadID("upload-a"),
                                      destination: DestinationRef("destination-a"),
                                      plan: ChunkPlan(totalBytes: 80, chunkSize: 4))
    private let upload = UploadID("upload-a")
    private let session = TransportSessionID("session-1")

    private var opened: [UploadEvent] {
        [.declared(intent), .transportSessionOpened(session)]
    }

    /// What the authority actually said: it holds 11, 12 and 13, and nothing else. It has
    /// never said anything about chunk 1.
    private var whatTheAuthoritySaid: UploadEvent {
        .authorityReported(Confirmation(upload: upload, session: session,
                                        progress: .chunks([ChunkID(11), ChunkID(12), ChunkID(13)])))
    }

    /// The marker-less ledger is a real implementation, not a caricature: it keeps the
    /// contract every `UploadEventLog` owes. That is what makes the control worth anything —
    /// the thing it lacks is the completeness marker, and nothing else.
    func testTheMarkerlessLedgerKeepsTheContractItIsMeasuredAgainst() async throws {
        try await EventLogContract.appendsMonotonicallyAndNeverAltersEarlierRecords(
            MarkerlessEventLog(directory: try temporaryDirectory()))
        try await EventLogContract.sequencesAreScopedToOneUpload(
            MarkerlessEventLog(directory: try temporaryDirectory()))
        try await EventLogContract.enumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot(
            MarkerlessEventLog(directory: try temporaryDirectory()))
    }

    /// Two bytes short of finishing one write, and the log now says the authority confirmed
    /// a chunk it never mentioned.
    ///
    /// `... chunks 11 12 13` cut two bytes short reads as `... chunks 11 12 1`. It parses,
    /// so the reader takes it, and a truncated ordinal is a perfectly good ordinal. Chunk 13
    /// is lost, which costs a re-send and is safe. Chunk 1 is *gained*, which is not: it is
    /// dropped from the plan and never sent, and no authority ever said it holds it.
    func testALedgerWithNoCompletenessMarkerDerivesProgressNobodyConfirmed() async throws {
        let directory = try temporaryDirectory()
        let log = MarkerlessEventLog(directory: directory)
        try await log.append(opened, for: upload)
        try await log.append([whatTheAuthoritySaid], for: upload)
        try takeBackTwoBytes(from: onlyFile(in: directory, suffix: MarkerlessEventLog.suffix))

        let coldStart = MarkerlessEventLog(directory: directory)
        let records = try await coldStart.records(for: upload)
        XCTAssertEqual(records.count, 3,
                       "the unfinished write is a record here, because nothing says it is not")

        let derived = UploadTransition.replay(records.map(\.event))
        guard case .transferring(_, _, let confirmed, _) = derived else {
            return XCTFail("expected a transfer in flight")
        }
        XCTAssertEqual(confirmed, .chunks([ChunkID(1), ChunkID(11), ChunkID(12)]),
                       "a truncated ordinal is a perfectly good ordinal")

        let scheduled = Set(ResumePlan.derive(for: intent, given: confirmed).transfers.map(\.chunk))
        XCTAssertFalse(scheduled.contains(ChunkID(1)),
                       "chunk 1 is not scheduled, and no authority ever confirmed it")
        XCTAssertTrue(scheduled.contains(ChunkID(13)),
                      "chunk 13 goes again, which is the harmless half of the same tear")
        XCTAssertEqual(intent.plan.range(of: ChunkID(1))?.count, 4,
                       "four bytes of the payload will never be sent, and the upload will finalize anyway")
    }

    /// The other half of the control. The same event, the same write cut two bytes short,
    /// and a ledger whose framing can tell that the record never finished.
    ///
    /// The difference is the completeness marker, not the diligence of the reader: this one
    /// derives that the authority has not answered at all, which is exactly what the log
    /// durably holds, and every chunk goes.
    func testTheFramedLedgerAfterTheSameTornWriteDerivesOnlyWhatWasDurablyRecorded() async throws {
        let directory = try temporaryDirectory()
        let log = FileEventLog(directory: directory)
        try await log.append(opened, for: upload)
        try await log.append([whatTheAuthoritySaid], for: upload)
        try takeBackTwoBytes(from: onlyFile(in: directory, suffix: ".ledger"))

        let coldStart = FileEventLog(directory: directory)
        let records = try await coldStart.records(for: upload)
        XCTAssertEqual(records.map(\.event), opened,
                       "the unfinished write is not a record, because the framing says so")

        let derived = UploadTransition.replay(records.map(\.event))
        guard case .transferring(_, _, let confirmed, _) = derived else {
            return XCTFail("expected a transfer in flight")
        }
        XCTAssertNil(confirmed, "the authority's answer never reached the log, so it did not answer")

        let scheduled = ResumePlan.derive(for: intent, given: confirmed).transfers.map(\.chunk)
        XCTAssertEqual(scheduled, intent.plan.chunks,
                       "every chunk goes, including the one the marker-less ledger skipped")
        XCTAssertTrue(scheduled.contains(ChunkID(1)))
    }

    // MARK: -

    /// Cut the last write short. The two ledgers write different bytes for the same event,
    /// so what "two bytes short" leaves behind differs — which is the whole comparison.
    private func takeBackTwoBytes(from file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let length = try Data(contentsOf: file).count
        try handle.truncate(atOffset: UInt64(length - 2))
    }

    private func onlyFile(in directory: URL, suffix: String) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(suffix) }
        XCTAssertEqual(names.count, 1, "expected exactly one \(suffix) file")
        return directory.appendingPathComponent(names[0])
    }
}
