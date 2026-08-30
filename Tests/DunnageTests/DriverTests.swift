import XCTest
import DunnageCore
import DunnageDriver

/// The driver executes and records, and the recording half is these two invariants: a
/// transport's answer becomes the one event that means it, and that event is durable before
/// the next transfer begins.
///
/// See `docs/adr/0005-the-driver-and-the-clock-it-waits-behind.md` §3.
final class DriverRecordingTests: XCTestCase {

    /// One attempt each, so a single refusal is the whole budget and the upload reaches a
    /// terminal phase inside one round. The point here is the log, not the arithmetic.
    private let policy = RetryPolicy(maxAttemptsPerChunk: 1,
                                     initialBackoff: .milliseconds(500),
                                     maximumBackoff: .seconds(4))

    // chunks 1...3, four bytes each
    private var intent: UploadIntent {
        UploadIntent(upload: UploadID("upload-a"),
                     destination: DestinationRef("destination-a"),
                     plan: ChunkPlan(totalBytes: 12, chunkSize: 4),
                     policy: policy)
    }

    private let session = TransportSessionID("session-1")

    private func held(_ chunks: Set<ChunkID>) -> Confirmation {
        Confirmation(upload: intent.upload, session: session, progress: .chunks(chunks))
    }

    /// One round in which the transport gives all three of the answers it has: a completion
    /// report, a refusal, and no answer at all. Each becomes its own event, in the order the
    /// answers arrived, and the log holds nothing else.
    ///
    /// The whole log is asserted rather than the three events, because "adds nothing to it"
    /// is a claim about what is *not* there. A driver that synthesised a refusal from an
    /// interruption would keep this log the same length.
    func testEachOfTheThreeAnswersBecomesTheOneEventThatMeansIt() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        await transport.script(.succeed, for: ChunkID(1))
        await transport.script(.refuse, for: ChunkID(2))
        await transport.script(.stall, for: ChunkID(3))
        let log = InMemoryEventLog()
        let driver = UploadDriver(transport: transport, log: log, clock: VirtualClock())

        let state = try await driver.run(intent)

        let written = try await log.records(for: intent.upload).map(\.event)
        XCTAssertEqual(written, [
            .declared(intent),
            .transportSessionOpened(session),
            .authorityReported(held([])),
            .chunkTransferReported(ChunkID(1)),
            .chunkTransferRefused(ChunkID(2)),
            .chunkTransferInterrupted(ChunkID(3)),
            .authorityReported(held([ChunkID(1)])),
            .abandoned(.retriesExhausted),
        ], "one event per answer, in the order the answers arrived, and nothing invented")

        XCTAssertEqual(state, .failed(intent: intent,
                                      reason: .retriesExhausted,
                                      confirmed: .chunks([ChunkID(1)])),
                       "the state is the fold of that log and of nothing the driver kept")
    }

    /// The tally is derived from the log, so a refusal that is still in memory when the
    /// process goes away is an attempt that never happened. A driver that collected a
    /// round's answers and appended them together would lose a whole round's budget to one
    /// process death, and an upload that dies on every attempt would retry for ever.
    ///
    /// The log and the transport write into one journal, so the order between them is read
    /// rather than inferred.
    func testAnAnswerIsOnTheLogBeforeTheNextTransferBegins() async throws {
        let journal = DriverJournal()
        let double = InMemoryTransportDouble(shape: .setShaped)
        await double.script(.refuse, for: ChunkID(2))
        let driver = UploadDriver(
            transport: JournallingTransport(wrapped: double, journal: journal),
            log: JournallingEventLog(wrapped: InMemoryEventLog(), journal: journal),
            clock: VirtualClock())

        _ = try await driver.run(intent)

        let entries = await journal.entries
        XCTAssertEqual(entries, [
            .appended(.declared(intent)),
            .appended(.transportSessionOpened(session)),
            .appended(.authorityReported(held([]))),
            .sent(ChunkID(1)),
            .appended(.chunkTransferReported(ChunkID(1))),
            .sent(ChunkID(2)),
            .appended(.chunkTransferRefused(ChunkID(2))),
            .sent(ChunkID(3)),
            .appended(.chunkTransferReported(ChunkID(3))),
            .appended(.authorityReported(held([ChunkID(1), ChunkID(3)]))),
            .appended(.abandoned(.retriesExhausted)),
        ], "every answer is durable before the transfer after it starts")
    }
}

/// `after` is a duration Core computed from the policy and the attempts already spent. The
/// driver is the thing that waits, and honouring it is not optional: it is the only place
/// backoff exists.
///
/// See ADR-0003 §4 and `docs/adr/0005-the-driver-and-the-clock-it-waits-behind.md` §4.
final class DriverWaitingTests: XCTestCase {

    private let policy = RetryPolicy(maxAttemptsPerChunk: 4,
                                     initialBackoff: .milliseconds(500),
                                     maximumBackoff: .seconds(4))

    // chunks 1...2, four bytes each
    private var intent: UploadIntent {
        UploadIntent(upload: UploadID("upload-b"),
                     destination: DestinationRef("destination-b"),
                     plan: ChunkPlan(totalBytes: 8, chunkSize: 4),
                     policy: policy)
    }

    private let session = TransportSessionID("session-1")

    private func held(_ chunks: Set<ChunkID>) -> Confirmation {
        Confirmation(upload: intent.upload, session: session, progress: .chunks(chunks))
    }

    /// Chunk 2 is refused once, so the second round has a wait to serve before it. The
    /// journal shows where the wait sits: after the answer that earned it, and before the
    /// transfer it delays.
    ///
    /// A driver that slept for 500 real milliseconds instead would leave no `.waited` entry
    /// here at all, because the wait is the clock's to record and the clock is the one the
    /// driver was handed. That is what "and not by sleeping" is asserting.
    func testTheWaitOnASendIsHonouredBeforeTheTransferAndByTheInjectedClock() async throws {
        let journal = DriverJournal()
        let double = InMemoryTransportDouble(shape: .setShaped)
        await double.scriptOnce(.refuse, for: ChunkID(2))
        let clock = VirtualClock()
        clock.grant(.milliseconds(500))
        let driver = UploadDriver(
            transport: JournallingTransport(wrapped: double, journal: journal),
            log: JournallingEventLog(wrapped: InMemoryEventLog(), journal: journal),
            clock: JournallingClock(wrapped: clock, journal: journal))

        let state = try await driver.run(intent)

        XCTAssertEqual(state, .completed(intent: intent))
        let entries = await journal.entries
        XCTAssertEqual(entries, [
            .appended(.declared(intent)),
            .appended(.transportSessionOpened(session)),
            .appended(.authorityReported(held([]))),
            .waited(.zero),
            .sent(ChunkID(1)),
            .appended(.chunkTransferReported(ChunkID(1))),
            .sent(ChunkID(2)),
            .appended(.chunkTransferRefused(ChunkID(2))),
            .appended(.authorityReported(held([ChunkID(1)]))),
            .waited(.milliseconds(500)),
            .sent(ChunkID(2)),
            .appended(.chunkTransferReported(ChunkID(2))),
            .appended(.authorityReported(held([ChunkID(1), ChunkID(2)]))),
            .appended(.finalized),
        ], "the wait the refusal earned sits between the answer and the retry")
    }

    /// Three refusals of one chunk, and the waits are exactly the doubling Core computes:
    /// nothing before the first attempt, then 500ms, 1s, 2s. The driver adds no wait of its
    /// own and skips none, including the one that is zero.
    ///
    /// The grants are what make that assertion sharp rather than decorative. A driver that
    /// took a wait this test did not grant would never come back, and one that skipped a
    /// wait would leave the grant unspent and the sequence short.
    ///
    /// Chunk 1 lands in the first round and is never sent again, which is the thesis showing
    /// through: the retries are for the chunk that was refused.
    func testTheOnlyWaitsTheDriverTakesAreTheOnesTheEffectsCarried() async throws {
        let intent = self.intent
        let transport = InMemoryTransportDouble(shape: .setShaped)
        for _ in 1...3 { await transport.scriptOnce(.refuse, for: ChunkID(2)) }
        let clock = VirtualClock()
        for backoff in [Duration.milliseconds(500), .seconds(1), .seconds(2)] {
            clock.grant(backoff)
        }
        let driver = UploadDriver(transport: transport, log: InMemoryEventLog(), clock: clock)

        let state = try await driver.run(intent)

        XCTAssertEqual(state, .completed(intent: intent))
        XCTAssertEqual(clock.waitsTaken,
                       [.zero, .milliseconds(500), .seconds(1), .seconds(2)],
                       "the doubling the policy computes, and nothing the driver added")
        let chunkOne = await transport.calls.filter { $0 == .sent(ChunkID(1)) }.count
        XCTAssertEqual(chunkOne, 1, "a confirmed chunk is not sent again while another retries")
    }
}
