import XCTest
import DunnageCore
import DunnageLedger

/// The written form of an event.
///
/// The format is a decision recorded in
/// `docs/adr/0004-the-on-disk-ledger-and-what-an-unreadable-record-does.md`, not a shape
/// derived from how Core happens to spell itself. These tests are what makes that true:
/// one pins the bytes, and one refuses to let a new event case slip through unwritten.
final class LedgerFormatTests: XCTestCase {

    private let upload = UploadID("u")
    private let session = TransportSessionID("s")

    private var intent: UploadIntent {
        UploadIntent(upload: upload,
                     destination: DestinationRef("d"),
                     payload: PayloadRef("p"),
                     plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    }

    /// One event per kind. The round-trip test asserts this covers `UploadEventKind`
    /// exhaustively, so adding a case to Core fails here until its written form is chosen.
    private var samples: [UploadEvent] {
        [.declared(intent),
         .transportSessionOpened(session),
         .chunkTransferReported(ChunkID(1)),
         .chunkTransferRefused(ChunkID(2)),
         .chunkTransferInterrupted(ChunkID(3)),
         .authorityReported(Confirmation(upload: upload, session: session,
                                         progress: .chunks([ChunkID(1), ChunkID(3)]))),
         .authorityReported(Confirmation(upload: upload, session: session,
                                         progress: .offset(ByteOffset(16)))),
         .finalized,
         .abandoned(.retriesExhausted)]
    }

    func testEveryEventKindHasOneWrittenFormAndSurvivesTheRoundTrip() throws {
        XCTAssertEqual(Set(samples.map(\.kind)), Set(UploadEventKind.allCases),
                       "an event kind with no sample here has no written form under test")

        for event in samples {
            let written = try LedgerFormat.encode(event)
            XCTAssertEqual(try LedgerFormat.decode(written), event,
                           "reading back \(event.kind) gave a different event")
            XCTAssertEqual(try LedgerFormat.encode(LedgerFormat.decode(written)), written,
                           "\(event.kind) has two written forms, not one")
        }

        // Every failure class the log distinguishes must also be written down.
        for reason in [FailureReason.retriesExhausted, .taskCancelled,
                       .systemTerminated, .userForceQuit] {
            let written = try LedgerFormat.encode(.abandoned(reason))
            XCTAssertEqual(try LedgerFormat.decode(written), .abandoned(reason),
                           "the class of failure did not survive the round trip")
        }
    }

    /// The bytes, pinned. A rename in Core that the compiler accepts must not be able to
    /// change what is already on someone's disk without this test saying so.
    func testTheWrittenFormOfAnEventIsPinnedByTheFormatAndNotBySwiftsSynthesis() throws {
        func written(_ event: UploadEvent) throws -> String {
            String(decoding: try LedgerFormat.encode(event), as: UTF8.self)
        }

        XCTAssertEqual(try written(.finalized), #"{"event":"finalized"}"#)
        XCTAssertEqual(try written(.chunkTransferReported(ChunkID(1))),
                       #"{"chunk":1,"event":"chunkTransferReported"}"#)
        XCTAssertEqual(try written(.chunkTransferRefused(ChunkID(2))),
                       #"{"chunk":2,"event":"chunkTransferRefused"}"#)
        XCTAssertEqual(try written(.chunkTransferInterrupted(ChunkID(3))),
                       #"{"chunk":3,"event":"chunkTransferInterrupted"}"#)
        XCTAssertEqual(try written(.transportSessionOpened(session)),
                       #"{"event":"transportSessionOpened","session":"s"}"#)
        XCTAssertEqual(try written(.abandoned(.userForceQuit)),
                       #"{"event":"abandoned","reason":"userForceQuit"}"#)

        // The sum type stays a sum type on disk: a tag, and exactly the field that shape
        // carries. Never two optional fields, which would make "both" and "neither"
        // writable.
        XCTAssertEqual(
            try written(.authorityReported(Confirmation(upload: upload, session: session,
                                                        progress: .chunks([ChunkID(3), ChunkID(1)])))),
            #"{"confirmation":{"progress":{"chunks":[1,3],"shape":"chunks"},"session":"s","upload":"u"},"event":"authorityReported"}"#,
            "a set has no order; its written form must, or the same event has two forms")
        XCTAssertEqual(
            try written(.authorityReported(Confirmation(upload: upload, session: session,
                                                        progress: .offset(ByteOffset(16))))),
            #"{"confirmation":{"progress":{"offset":16,"shape":"offset"},"session":"s","upload":"u"},"event":"authorityReported"}"#)

        XCTAssertEqual(
            try written(.declared(intent)),
            #"{"event":"declared","intent":{"destination":"d","payload":"p","plan":{"chunkSize":4,"totalBytes":20},"policy":{"initialBackoff":{"attoseconds":0,"seconds":1},"maxAttemptsPerChunk":3,"maximumBackoff":{"attoseconds":0,"seconds":60}},"upload":"u"}}"#,
            "the declaration carries the whole intent, because replaying the log alone rebuilds it")
    }

    /// ADR-0001 O-1, decided by ADR-0004. A newer build's record is complete and well
    /// formed, and this binary still has no meaning for what it says. It is refused, by
    /// name, and the name is what it could not read rather than only that it could not.
    ///
    /// A newer event, a newer failure class and a newer progress shape are the same
    /// situation. Reading past any of them derives an upload the log does not describe.
    func testARecordNamingAnEventThisBinaryDoesNotKnowIsNeverGuessedAt() throws {
        let fromALaterBuild: [(String, RecordFault, String)] = [
            ("an event", .unknownToken(field: "event", token: "chunkTransferDisavowed"),
             #"{"chunk":2,"event":"chunkTransferDisavowed"}"#),
            ("a failure class", .unknownToken(field: "reason", token: "networkInterrupted"),
             #"{"event":"abandoned","reason":"networkInterrupted"}"#),
            ("a progress shape", .unknownToken(field: "shape", token: "frontier"),
             #"{"confirmation":{"progress":{"shape":"frontier"},"session":"s","upload":"u"},"event":"authorityReported"}"#),
            ("a field on an event this binary does have",
             .unknownToken(field: "chunkTransferReported", token: "checksum"),
             #"{"checksum":"ab","chunk":2,"event":"chunkTransferReported"}"#),
        ]

        for (what, expected, payload) in fromALaterBuild {
            XCTAssertThrowsError(try LedgerFormat.decode(Array(payload.utf8)),
                                 "\(what): was read rather than refused") { error in
                XCTAssertEqual(error as? RecordFault, expected,
                               "\(what): refused without saying what it could not read")
            }
        }
    }

    /// Complete, and not what the format says. Refused rather than read as far as it goes:
    /// a payload with a chunk ordinal of zero is not a chunk, and repairing it into one
    /// would derive an upload nobody declared.
    func testACompleteRecordThisBinaryCannotInterpretIsRefusedRatherThanRepaired() throws {
        let refusable: [(String, String)] = [
            ("not JSON at all",            "chunkTransferReported 2"),
            ("a JSON array, not a record", #"["chunkTransferReported",2]"#),
            ("no event tag",               #"{"chunk":2}"#),
            ("a tag that is not a string", #"{"chunk":2,"event":7}"#),
            ("a missing field",            #"{"event":"chunkTransferReported"}"#),
            ("a field of the wrong type",  #"{"chunk":"two","event":"chunkTransferReported"}"#),
            ("a boolean read as an ordinal", #"{"chunk":true,"event":"chunkTransferReported"}"#),
            ("a chunk ordinal of zero",    #"{"chunk":0,"event":"chunkTransferReported"}"#),
            ("a negative byte offset",
             #"{"confirmation":{"progress":{"offset":-1,"shape":"offset"},"session":"s","upload":"u"},"event":"authorityReported"}"#),
            ("a chunk size of zero",
             #"{"event":"declared","intent":{"destination":"d","payload":"p","plan":{"chunkSize":0,"totalBytes":20},"policy":{"initialBackoff":{"attoseconds":0,"seconds":1},"maxAttemptsPerChunk":3,"maximumBackoff":{"attoseconds":0,"seconds":60}},"upload":"u"}}"#),
            ("a retry cap below the first wait",
             #"{"event":"declared","intent":{"destination":"d","payload":"p","plan":{"chunkSize":4,"totalBytes":20},"policy":{"initialBackoff":{"attoseconds":0,"seconds":60},"maxAttemptsPerChunk":3,"maximumBackoff":{"attoseconds":0,"seconds":1}},"upload":"u"}}"#),
        ]

        for (what, payload) in refusable {
            XCTAssertThrowsError(try LedgerFormat.decode(Array(payload.utf8)),
                                 "\(what): was read rather than refused") { error in
                guard case .malformed = error as? RecordFault else {
                    return XCTFail("\(what): refused as \(error), which is not what it is")
                }
            }
        }
    }
}
