import XCTest
import DunnageCore
import DunnageDriver

/// The negative control for phase 3.
///
/// Phase 1's control is bytes re-sent that were confirmed. Phase 2's is bytes skipped that
/// were not. This one is neither: it is an upload abandoned that nothing was wrong with.
///
/// Same transport, same script, same policy, same clock. A chunk goes quiet three times and
/// then lands; nothing anywhere ever answers no. One driver finishes the upload. The other
/// gives up on it while the authority was holding four of the five chunks — and the log it
/// leaves behind is internally consistent, which is what makes this the dangerous one. Every
/// event on it is well formed, `.failed(.retriesExhausted)` is exactly what those events
/// derive, and Core's conclusion is correct about evidence that is false.
///
/// It is never "fixed". If the concluding driver ever stops giving up here, the control has
/// been broken and the real driver has nothing left to be measured against.
final class DriverNegativeControlTests: XCTestCase {

    private let policy = RetryPolicy(maxAttemptsPerChunk: 3,
                                     initialBackoff: .milliseconds(500),
                                     maximumBackoff: .seconds(4))

    // chunks 1...5, four bytes each
    private var intent: UploadIntent {
        UploadIntent(upload: UploadID("upload-g"),
                     destination: DestinationRef("destination-g"),
                     plan: ChunkPlan(totalBytes: 20, chunkSize: 4),
                     policy: policy)
    }

    /// Chunks 1 to 4 land at the first attempt. Chunk 5's transfer says nothing three times
    /// and lands on the fourth. No transport call refuses anything, ever.
    private func flakyTransport() async -> InMemoryTransportDouble {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        for _ in 1...3 { await transport.scriptOnce(.stall, for: ChunkID(5)) }
        return transport
    }

    private func refusals(on log: InMemoryEventLog) async throws -> Int {
        try await log.records(for: intent.upload).filter {
            if case .chunkTransferRefused = $0.event { true } else { false }
        }.count
    }

    /// The control's own contract. It has to be a driver, not a broken thing that fails at
    /// everything — otherwise it would only show that a worse implementation is worse.
    /// Given a transport that answers, it drives an upload to completion like any other.
    func testTheConcludingDriverKeepsTheContractItIsMeasuredAgainst() async throws {
        let intent = self.intent
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let log = InMemoryEventLog()

        let state = try await ConcludingDriver(transport: transport, log: log,
                                               clock: VirtualClock()).run(intent)

        XCTAssertEqual(state, .completed(intent: intent))
        let sent = await transport.calls.filter { if case .sent = $0 { true } else { false } }
        XCTAssertEqual(sent.count, 5, "one transfer per chunk, and no chunk sent twice")
    }

    /// The failure. Three transfers that nobody answered for are written down as three
    /// refusals, the budget is spent on a chunk that was never refused, and the upload is
    /// given up on one attempt before the one that would have finished it.
    ///
    /// Four of the five chunks are confirmed at the authority when it happens. That is the
    /// cost ADR-0002 names: not the bound failing, but the upload giving up while the
    /// authority was holding most of it.
    func testADriverThatCallsAnInterruptionARefusalGivesUpOnAnUploadNothingRefused() async throws {
        let intent = self.intent
        let transport = await flakyTransport()
        let clock = VirtualClock()
        clock.grant(.milliseconds(500))     // the backoff its first invented refusal earns
        clock.grant(.seconds(1))            // and its second
        let log = InMemoryEventLog()

        let state = try await ConcludingDriver(transport: transport, log: log,
                                               clock: clock).run(intent)

        XCTAssertEqual(state, .failed(intent: intent,
                                      reason: .retriesExhausted,
                                      confirmed: .chunks([ChunkID(1), ChunkID(2),
                                                          ChunkID(3), ChunkID(4)])),
                       "given up on, with four of the five chunks confirmed")
        let invented = try await refusals(on: log)
        XCTAssertEqual(invented, 3, "three refusals on the log, and no transport ever refused")
        let sent = await transport.calls.filter { $0 == .sent(ChunkID(5)) }.count
        XCTAssertEqual(sent, 3, "it stopped one transfer short of the one that would have landed")
    }

    /// The other half. The same transport, the same script, the same policy — and the driver
    /// that records what actually happened finishes the upload.
    ///
    /// The three interruptions cost nothing, so there is no backoff to grant and no budget to
    /// run out of, and the fourth transfer of chunk 5 lands. The difference between the two
    /// runs is one line of mapping, not the transport and not the diligence of the client.
    func testTheRealDriverAfterTheSameInterruptionsFinishesTheUpload() async throws {
        let intent = self.intent
        let transport = await flakyTransport()
        let clock = VirtualClock()
        clock.grant(.milliseconds(500))     // the same clock, with the same backoffs
        clock.grant(.seconds(1))            // available — and this driver takes neither
        let log = InMemoryEventLog()

        let state = try await UploadDriver(transport: transport, log: log, clock: clock,
                                           quietAfter: neverReached).run(intent)

        XCTAssertEqual(state, .completed(intent: intent))
        let invented = try await refusals(on: log)
        XCTAssertEqual(invented, 0, "nothing refused anything, so nothing on the log says so")
        XCTAssertEqual(clock.waitsTaken, [.zero, .zero, .zero, .zero],
                       "an interruption earns no backoff, so every send went straight out")
        let sent = await transport.calls.filter { $0 == .sent(ChunkID(5)) }.count
        XCTAssertEqual(sent, 4, "it made the transfer the other one gave up before")
    }
}
