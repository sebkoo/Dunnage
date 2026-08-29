import XCTest
import DunnageCore

/// The negative control.
///
/// This demonstrates the failure mode the thesis claims to remove. It is not a bug and it
/// is never "fixed": if it ever stops failing to resume, the control has been broken and
/// the thesis has lost the thing it is measured against.
final class NegativeControlTests: XCTestCase {

    // chunks 1...5, four bytes each
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))

    private func transfer(_ ordinal: Int) -> PlannedTransfer {
        let chunk = ChunkID(ordinal)
        return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
    }

    private func bytesToSend(_ progress: ConfirmedProgress) -> Int {
        ResumePlan.derive(for: intent, given: progress).transfers.reduce(0) { $0 + $1.range.count }
    }

    /// A transport whose authority has no unit smaller than the whole object can confirm
    /// nothing until the object exists. Interrupt it at 80% and it holds nothing, so
    /// recovery re-sends all twenty bytes.
    ///
    /// Nothing in Core is at fault here. This is what the transport contract permits, and
    /// it is why "the app kept running in the background" is not a durability claim.
    func testWholeObjectTransportDouble_ResendsEveryByteAfterInterruption() async throws {
        let transport = InMemoryTransportDouble(shape: .offsetShaped, durability: .retainsNothing)
        let session = try await transport.openSession(for: intent)

        for ordinal in [1, 2, 3, 4] { _ = try await transport.send(transfer(ordinal), in: session) }
        let before = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(before.progress, .offset(ByteOffset(16)), "sixteen of twenty bytes went out")

        await transport.interrupt(session)

        let after = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(after.progress, .offset(ByteOffset(0)),
                       "a whole-object authority holds nothing confirmable until the object exists")

        let plan = ResumePlan.derive(for: intent, given: after.progress)
        XCTAssertEqual(plan.transfers.map(\.chunk), intent.plan.chunks,
                       "every chunk has to go again")
        XCTAssertEqual(bytesToSend(after.progress), intent.plan.totalBytes,
                       "every byte has to go again: sixteen bytes of work is lost")
    }

    /// The control's other half. Same interruption, same point in the transfer — but an
    /// authority that can name units keeps them, so only the four bytes that were never
    /// confirmed go again.
    ///
    /// The difference is the transport's contract, not the client's diligence.
    func testUnitHoldingAuthorityAfterTheSameInterruptionResendsOnlyWhatItNeverConfirmed() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped,
                                                durability: .retainsCompletedUnits)
        let session = try await transport.openSession(for: intent)

        for ordinal in [1, 2, 3, 4] { _ = try await transport.send(transfer(ordinal), in: session) }
        await transport.interrupt(session)

        let after = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(after.progress, .chunks([ChunkID(1), ChunkID(2), ChunkID(3), ChunkID(4)]),
                       "an authority that names units still holds them after the connection drops")
        XCTAssertEqual(ResumePlan.derive(for: intent, given: after.progress).transfers.map(\.chunk),
                       [ChunkID(5)])
        XCTAssertEqual(bytesToSend(after.progress), 4,
                       "four bytes against the whole-object transport's twenty")
    }
}
