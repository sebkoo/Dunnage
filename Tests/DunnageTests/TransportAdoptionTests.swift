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
}
