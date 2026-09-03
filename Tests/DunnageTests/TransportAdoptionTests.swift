import XCTest
import DunnageCore
@testable import DunnageTransport

/// A task this transport did not name is cancelled and never read as progress.
///
/// ADR-0007 §4: on creation the transport asks the session for its pending tasks and adopts
/// each by its description. One it cannot name is not evidence about any upload.
/// Deterministic, on the scripted wire; nothing here touches a session.
final class TransportAdoptionTests: XCTestCase {

    /// Two tasks the daemon still holds from a previous process: one named for chunk 2 of
    /// upload `a`, one described as `garbage`. After `adopt()`, chunk 2 is in flight, the
    /// garbage task was cancelled, and the named one was not.
    func testATaskWhoseDescriptionThisTransportDidNotMintIsCancelledAndNeverReadAsProgress() async throws {
        let wire = ScriptedWire()
        let named = await wire.seedPending(description: #"{"chunk":2,"session":"r/u","upload":"a"}"#)
        let garbage = await wire.seedPending(description: "garbage")

        let transport = BackgroundSessionTransport(
            plane: CannedPlane { _ in XCTFail("adoption asked the plane"); throw CancellationError() },
            tasks: wire,
            chunkFiles: ChunkFiles(directory: try temporaryDirectory(), resolve: { _ in URL(fileURLWithPath: "/") }))
        await transport.adopt()

        let inFlight = await transport.inFlightChunks(of: UploadID("a"))
        XCTAssertEqual(inFlight, [ChunkID(2)],
                       "the chunks in flight are not exactly the ones named tasks name")

        let journal = await wire.journal
        XCTAssertTrue(journal.contains(.cancel(garbage)),
                      "a task this transport did not name was kept: \(journal)")
        XCTAssertFalse(journal.contains(.cancel(named)),
                       "a task this transport did name was cancelled: \(journal)")
    }

    /// Two pending tasks under one description, ids 1 and 2. Adoption keeps the first —
    /// the lowest id, after sorting, because the session promises no order — and cancels
    /// the other; the chunk is in flight once.
    func testAdoptionKeepsTheFirstTaskPerChunkAndCancelsADuplicate() async throws {
        let wire = ScriptedWire()
        let description = #"{"chunk":3,"session":"r/u","upload":"a"}"#
        let first = await wire.seedPending(description: description)
        let duplicate = await wire.seedPending(description: description)
        XCTAssertEqual([first, duplicate], [PartTaskID(1), PartTaskID(2)],
                       "the wire did not mint the ids this test's rule is stated against")

        let transport = BackgroundSessionTransport(
            plane: CannedPlane { _ in XCTFail("adoption asked the plane"); throw CancellationError() },
            tasks: wire,
            chunkFiles: ChunkFiles(directory: try temporaryDirectory(), resolve: { _ in URL(fileURLWithPath: "/") }))
        await transport.adopt()

        let journal = await wire.journal
        XCTAssertTrue(journal.contains(.cancel(duplicate)),
                      "the duplicate task was kept: \(journal)")
        XCTAssertFalse(journal.contains(.cancel(first)),
                       "the first task was cancelled: \(journal)")
        let inFlight = await transport.inFlightChunks(of: UploadID("a"))
        XCTAssertEqual(inFlight, [ChunkID(3)], "chunk 3 is not in flight exactly once")
    }
}
