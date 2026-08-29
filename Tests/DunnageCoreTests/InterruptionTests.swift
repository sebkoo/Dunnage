import XCTest
import DunnageCore

/// An interruption is the absence of an answer.
///
/// A chunk in flight when the connection drops is unconfirmed: it may have landed and it
/// may not, and only the authority can settle which. Calling that a failure spends a
/// retry budget on a chunk that was never in trouble; calling it a success drops bytes on
/// the floor. Core does neither — it asks.
final class InterruptionTests: XCTestCase {

    // chunks 1...5, four bytes each
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))

    private func transfer(_ ordinal: Int) -> PlannedTransfer {
        let chunk = ChunkID(ordinal)
        return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
    }

    private func step(_ event: UploadEvent,
                      _ state: inout UploadMachineState,
                      _ context: String,
                      file: StaticString = #filePath, line: UInt = #line) -> [UploadEffect] {
        guard case .accepted(let next, let effects) = UploadTransition.apply(event, to: state)
        else {
            XCTFail("\(context): \(event) was rejected in \(state.phase.rawValue)",
                    file: file, line: line)
            return []
        }
        state = next
        return effects
    }

    /// The connection drops while chunk 3 is in flight.
    ///
    /// Whether chunk 3's bytes reached the authority is settled by the transport, not by
    /// Core, so the test runs it both ways. The interruption Core is handed is identical
    /// in both runs — that is what an absent answer means — and the state it leaves behind
    /// is identical too. What resume schedules differs, and it differs only because the
    /// authority answered differently.
    func testNetworkInterruptionMidChunk_LeavesTheChunkUnconfirmedNotFailed() async throws {
        for landed in [true, false] {
            let context = landed ? "the in-flight chunk landed" : "the in-flight chunk did not land"

            let transport = InMemoryTransportDouble(shape: .setShaped)
            let session = try await transport.openSession(for: intent)
            await transport.script(landed ? .landWithoutAnswering : .stall, for: ChunkID(3))

            var state = UploadTransition.replay([.declared(intent),
                                                 .transportSessionOpened(session)])

            // Chunks 1 and 2 go out, are reported, and are then confirmed by the authority.
            for ordinal in [1, 2] {
                let outcome = try await transport.send(transfer(ordinal), in: session)
                XCTAssertEqual(outcome, .reportedComplete(ChunkID(ordinal)), context)
                _ = step(.chunkTransferReported(ChunkID(ordinal)), &state, context)
            }
            _ = step(.authorityReported(try await transport.confirmedProgress(in: session)),
                     &state, context)
            let beforeInterruption = state

            // Chunk 3 goes out and the answer never arrives.
            let outcome = try await transport.send(transfer(3), in: session)
            XCTAssertEqual(outcome, .interrupted(ChunkID(3)),
                           "\(context): an interruption is the same non-answer either way")

            let effects = step(.chunkTransferInterrupted(ChunkID(3)), &state, context)

            XCTAssertEqual(state, beforeInterruption,
                           "\(context): an interruption moved the state; it settles nothing")
            XCTAssertFalse(state.isTerminal,
                           "\(context): an interruption is not a failure and must not end the upload")
            XCTAssertEqual(effects, [.askAuthorityForConfirmedProgress(intent.upload, session)],
                           "\(context): after an interruption Core asks the authority, and does nothing else")

            // Only now, and only from the authority, does chunk 3's fate become known.
            let scheduled = step(
                .authorityReported(try await transport.confirmedProgress(in: session)),
                &state, context)

            guard case .send(let transfers, _, _)? = scheduled.first else {
                return XCTFail("\(context): the authority's answer must schedule the rest")
            }
            XCTAssertEqual(transfers.map(\.chunk),
                           landed ? [ChunkID(4), ChunkID(5)]
                                  : [ChunkID(3), ChunkID(4), ChunkID(5)],
                           "\(context): what resume sends is decided by the authority alone")
        }
    }
}
