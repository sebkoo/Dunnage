import XCTest
import DunnageCore

/// The contract the in-memory transport double owes. A fake that disagrees with the
/// protocol makes every test standing on it worthless, so the fake is tested too.
final class TransportContractTests: XCTestCase {

    // chunks 1...5, four bytes each
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))

    private func transfer(_ ordinal: Int) -> PlannedTransfer {
        let chunk = ChunkID(ordinal)
        return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
    }

    func testTransportDoubleIssuesDistinctSessionsAndRefusesUnknownOnes() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let first = try await transport.openSession(for: intent)
        let second = try await transport.openSession(for: intent)
        XCTAssertNotEqual(first, second,
                          "each transport operation is its own identity; part 3 of one is not part 3 of another")

        do {
            _ = try await transport.confirmedProgress(in: TransportSessionID("never-opened"))
            XCTFail("an authority cannot report on an operation it has no record of")
        } catch let error as TransportError {
            XCTAssertEqual(error, .unknownSession)
        }
    }

    /// A set-shaped authority holds what it holds. Sending 1, 2 and 4 leaves a gap at 3,
    /// and the authority says so rather than smoothing it into a frontier.
    func testTransportDoubleReportsSetShapedProgressIncludingGaps() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)

        for ordinal in [1, 2, 4] {
            let outcome = try await transport.send(transfer(ordinal), in: session)
            XCTAssertEqual(outcome, .reportedComplete(ChunkID(ordinal)))
        }

        let confirmation = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(confirmation.upload, intent.upload)
        XCTAssertEqual(confirmation.session, session)
        XCTAssertEqual(confirmation.progress, .chunks([ChunkID(1), ChunkID(2), ChunkID(4)]))
    }

    /// An offset-shaped authority can only report a contiguous prefix. Sending 1, 2 and 4
    /// means it can state 8 bytes, not 12: it may hold chunk 4, but it cannot say so.
    func testTransportDoubleReportsOffsetShapedProgressAsAContiguousPrefixOnly() async throws {
        let transport = InMemoryTransportDouble(shape: .offsetShaped)
        let session = try await transport.openSession(for: intent)

        for ordinal in [1, 2, 4] {
            _ = try await transport.send(transfer(ordinal), in: session)
        }

        let confirmation = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(confirmation.progress, .offset(ByteOffset(8)),
                       "the prefix stops at the gap, whatever else the authority is holding")
    }

    func testTransportDoubleScriptedToFailStoresNothingForThatChunk() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        await transport.script(.fail(.networkInterrupted), for: ChunkID(2))

        _ = try await transport.send(transfer(1), in: session)
        let outcome = try await transport.send(transfer(2), in: session)
        XCTAssertEqual(outcome, .failed(.networkInterrupted))

        let confirmation = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(confirmation.progress, .chunks([ChunkID(1)]),
                       "a failed transfer confirms nothing")
    }

    /// A stall produces no outcome. The authority is the only thing that can settle whether
    /// the bytes landed, and here they did not.
    func testTransportDoubleScriptedToStallProducesNoOutcome() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        await transport.script(.stall, for: ChunkID(1))

        let outcome = try await transport.send(transfer(1), in: session)
        XCTAssertEqual(outcome, .stalled)

        let confirmation = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(confirmation.progress, .chunks([]), "a stalled transfer confirms nothing")
        let reports = await transport.deliveredReports
        XCTAssertEqual(reports, [], "a stall reports nothing at all")
    }

    /// Transports do deliver the same completion twice. The double can, so the behaviour
    /// can be tested against rather than assumed away.
    func testTransportDoubleScriptedToDuplicateDeliversTheSameReportTwice() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        await transport.script(.duplicate, for: ChunkID(1))

        _ = try await transport.send(transfer(1), in: session)
        _ = try await transport.send(transfer(2), in: session)

        let reports = await transport.deliveredReports
        XCTAssertEqual(reports, [ChunkID(1), ChunkID(1), ChunkID(2)],
                       "the duplicated report arrives twice; the other once")
        let confirmation = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(confirmation.progress, .chunks([ChunkID(1), ChunkID(2)]),
                       "delivering a report twice does not make the authority hold more")
    }

    /// An authority that has forgotten an operation cannot be asked about it. This is what
    /// an aborted or expired multipart upload looks like from the client.
    func testTransportDoubleThatForgotASessionCannotBeAskedAboutIt() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        _ = try await transport.send(transfer(1), in: session)

        await transport.forget(session)
        do {
            _ = try await transport.confirmedProgress(in: session)
            XCTFail("a forgotten operation cannot be reported on")
        } catch let error as TransportError {
            XCTAssertEqual(error, .unknownSession)
        }
    }

    /// An uploaded part is not a completed object. Finalization fails while the authority
    /// holds less than everything, and succeeds once it holds it all.
    func testTransportDoubleRefusesToFinalizeAnIncompleteUpload() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        for ordinal in [1, 2, 3, 4] { _ = try await transport.send(transfer(ordinal), in: session) }

        do {
            try await transport.finalize(session)
            XCTFail("four of five units is not an object")
        } catch let error as TransportError {
            XCTAssertEqual(error, .incompleteUpload)
        }
        let notYet = await transport.isFinalized(session)
        XCTAssertFalse(notYet)

        _ = try await transport.send(transfer(5), in: session)
        try await transport.finalize(session)
        let now = await transport.isFinalized(session)
        XCTAssertTrue(now, "with every unit held, the object can be created")
    }
}
