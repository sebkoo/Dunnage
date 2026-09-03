import XCTest
import DunnageCore

/// The contract the in-memory transport double owes. A fake that disagrees with the
/// protocol makes every test standing on it worthless, so the fake is tested too.
final class TransportContractTests: XCTestCase {

    // chunks 1...5, four bytes each
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        payload: PayloadRef("payload-a"),
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
            _ = try await transport.confirmedProgress(for: intent.upload, in: TransportSessionID("never-opened"))
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
            let outcome = try await transport.send(transfer(ordinal), of: intent, in: session)
            XCTAssertEqual(outcome, .reportedComplete(ChunkID(ordinal)))
        }

        let confirmation = try await transport.confirmedProgress(for: intent.upload, in: session)
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
            _ = try await transport.send(transfer(ordinal), of: intent, in: session)
        }

        let confirmation = try await transport.confirmedProgress(for: intent.upload, in: session)
        XCTAssertEqual(confirmation.progress, .offset(ByteOffset(8)),
                       "the prefix stops at the gap, whatever else the authority is holding")
    }

    /// A refusal is an answer, and a negative one: nothing landed, and the transport is in
    /// a position to say so. It is a different statement from an interruption, and the
    /// call site can tell the two apart.
    func testTransportDoubleScriptedToRefuseAnswersNoAndStoresNothing() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        await transport.script(.refuse, for: ChunkID(2))

        _ = try await transport.send(transfer(1), of: intent, in: session)
        let outcome = try await transport.send(transfer(2), of: intent, in: session)
        XCTAssertEqual(outcome, .refused(ChunkID(2)))

        let confirmation = try await transport.confirmedProgress(for: intent.upload, in: session)
        XCTAssertEqual(confirmation.progress, .chunks([ChunkID(1)]),
                       "a refused transfer confirms nothing")
        let reports = await transport.deliveredReports
        XCTAssertEqual(reports, [ChunkID(1)],
                       "a refusal is an answer, not a completion report")
    }

    /// A stall and a transfer that landed without ever answering produce the same outcome,
    /// and they have to: the answer never arrived, so the outcome cannot carry a claim
    /// about whether the bytes reached the authority. Only the authority separates them.
    func testTransportDoubleScriptedToStallOrToLandSilentlyGivesTheSameNonAnswer() async throws {
        var confirmed: [ConfirmedProgress] = []

        for behavior in [InMemoryTransportDouble.Behavior.stall, .landWithoutAnswering] {
            let transport = InMemoryTransportDouble(shape: .setShaped)
            let session = try await transport.openSession(for: intent)
            await transport.script(behavior, for: ChunkID(1))

            let outcome = try await transport.send(transfer(1), of: intent, in: session)
            XCTAssertEqual(outcome, .interrupted(ChunkID(1)),
                           "\(behavior): an interruption is the absence of an answer")
            let reports = await transport.deliveredReports
            XCTAssertEqual(reports, [],
                           "\(behavior): nothing was reported, because nothing answered")

            confirmed.append(try await transport.confirmedProgress(for: intent.upload, in: session).progress)
        }

        XCTAssertEqual(confirmed, [.chunks([]), .chunks([ChunkID(1)])],
                       "the authority, and only the authority, says which interruption landed")
    }

    /// Transports do deliver the same completion twice. The double can, so the behaviour
    /// can be tested against rather than assumed away.
    func testTransportDoubleScriptedToDuplicateDeliversTheSameReportTwice() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        await transport.script(.duplicate, for: ChunkID(1))

        _ = try await transport.send(transfer(1), of: intent, in: session)
        _ = try await transport.send(transfer(2), of: intent, in: session)

        let reports = await transport.deliveredReports
        XCTAssertEqual(reports, [ChunkID(1), ChunkID(1), ChunkID(2)],
                       "the duplicated report arrives twice; the other once")
        let confirmation = try await transport.confirmedProgress(for: intent.upload, in: session)
        XCTAssertEqual(confirmation.progress, .chunks([ChunkID(1), ChunkID(2)]),
                       "delivering a report twice does not make the authority hold more")
    }

    /// An authority that has forgotten an operation cannot be asked about it. This is what
    /// an aborted or expired multipart upload looks like from the client.
    func testTransportDoubleThatForgotASessionCannotBeAskedAboutIt() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        _ = try await transport.send(transfer(1), of: intent, in: session)

        await transport.forget(session)
        do {
            _ = try await transport.confirmedProgress(for: intent.upload, in: session)
            XCTFail("a forgotten operation cannot be reported on")
        } catch let error as TransportError {
            XCTAssertEqual(error, .unknownSession)
        }
    }

    /// ADR-0007 §3: `confirmedProgress` names the upload its answer is about. An authority
    /// asked about an operation under another upload has no record of it, and the double
    /// says so rather than answering about the session it does hold under a different name.
    func testTransportDoubleRefusesAProgressQuestionNamingAnotherUpload() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        _ = try await transport.send(transfer(1), of: intent, in: session)

        do {
            _ = try await transport.confirmedProgress(for: UploadID("upload-b"), in: session)
            XCTFail("an operation under another upload has no record under this one")
        } catch let error as TransportError {
            XCTAssertEqual(error, .unknownSession)
        }
    }

    /// An uploaded part is not a completed object. Finalization fails while the authority
    /// holds less than everything, and succeeds once it holds it all.
    func testTransportDoubleRefusesToFinalizeAnIncompleteUpload() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        for ordinal in [1, 2, 3, 4] { _ = try await transport.send(transfer(ordinal), of: intent, in: session) }

        do {
            try await transport.finalize(session)
            XCTFail("four of five units is not an object")
        } catch let error as TransportError {
            XCTAssertEqual(error, .incompleteUpload)
        }
        let notYet = await transport.isFinalized(session)
        XCTAssertFalse(notYet)

        _ = try await transport.send(transfer(5), of: intent, in: session)
        try await transport.finalize(session)
        let now = await transport.isFinalized(session)
        XCTAssertTrue(now, "with every unit held, the object can be created")
    }
}
