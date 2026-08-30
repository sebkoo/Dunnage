import XCTest
import DunnageCore
import DunnageDriver

/// The doubles phase 3 introduces, held against the contracts they stand in for.
///
/// A fake that quietly disagrees with the thing it replaces makes every test standing on it
/// worthless, and these three carry more weight than most: the clock is what makes every
/// timing assertion in this phase deterministic, and the journal is what makes an ordering
/// between two objects readable at all.
final class DriverDoubleContractTests: XCTestCase {

    // chunks 1...2, four bytes each
    private var intent: UploadIntent {
        UploadIntent(upload: UploadID("upload-a"),
                     destination: DestinationRef("destination-a"),
                     plan: ChunkPlan(totalBytes: 8, chunkSize: 4))
    }

    private func transfer(_ ordinal: Int) -> PlannedTransfer {
        let chunk = ChunkID(ordinal)
        return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
    }

    /// A wait elapses when a test grants it and not before, and a wait of no time needs no
    /// grant at all. The second half is what lets `waitsTaken` say "including the zero one"
    /// without every test having to grant the wait before the first attempt.
    func testTheVirtualClockLetsAWaitElapseOnlyWhenATestHasGrantedIt() async throws {
        let clock = VirtualClock()

        try await clock.wait(for: .zero)
        XCTAssertEqual(clock.waitsTaken, [.zero], "a wait of no time is still a wait, taken")

        let waiter = Task { try await clock.wait(for: .seconds(5)) }
        while clock.waitsRequested.count < 2 { await Task.yield() }
        XCTAssertEqual(clock.waitsTaken, [.zero], "an ungranted wait has not elapsed")

        clock.grant(.seconds(5))
        try await waiter.value
        XCTAssertEqual(clock.waitsTaken, [.zero, .seconds(5)])
        XCTAssertEqual(clock.waitsRequested, [.zero, .seconds(5)])
    }

    /// A grant is spent by the wait that takes it. Two waits and one grant is a test that
    /// hangs, which is the failure a test wants: a driver that took a wait nobody sanctioned
    /// must not be able to pass by taking someone else's.
    func testTheVirtualClockSpendsAGrantOnOneWaitAndNoMore() async throws {
        let clock = VirtualClock()
        clock.grant(.seconds(5), times: 2)

        try await clock.wait(for: .seconds(5))
        try await clock.wait(for: .seconds(5))
        XCTAssertEqual(clock.waitsTaken, [.seconds(5), .seconds(5)])

        let third = Task { try await clock.wait(for: .seconds(5)) }
        while clock.waitsRequested.count < 3 { await Task.yield() }
        XCTAssertEqual(clock.waitsTaken.count, 2, "the third wait has nothing left to spend")
        third.cancel()
        _ = try? await third.value
    }

    /// A wait its task no longer needs is abandoned rather than completed, which is what
    /// makes `waitsTaken` the sequence of waits actually taken rather than of waits armed.
    func testTheVirtualClockAbandonsAWaitItsTaskNoLongerNeeds() async throws {
        let clock = VirtualClock()
        let waiter = Task { try await clock.wait(for: .seconds(5)) }
        while clock.waitsRequested.isEmpty { await Task.yield() }

        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled wait does not elapse")
        } catch is CancellationError {
            // as expected
        }

        XCTAssertEqual(clock.waitsRequested, [.seconds(5)], "it was asked for")
        XCTAssertEqual(clock.waitsTaken, [], "and it was not taken")
    }

    /// A transport that answers differently on the second try is the ordinary case, not an
    /// exotic one. Queued answers come first, in the order they were queued, and then the
    /// chunk goes back to whatever it was scripted to do standingly.
    func testTheDoubleScriptedOnceAnswersThatWayOnceAndThenAsItWasBefore() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        await transport.script(.succeed, for: ChunkID(1))
        await transport.scriptOnce(.refuse, for: ChunkID(1))
        await transport.scriptOnce(.stall, for: ChunkID(1))
        let session = try await transport.openSession(for: intent)

        var answers: [TransferOutcome] = []
        for _ in 1...4 { answers.append(try await transport.send(transfer(1), in: session)) }

        XCTAssertEqual(answers, [.refused(ChunkID(1)),
                                 .interrupted(ChunkID(1)),
                                 .reportedComplete(ChunkID(1)),
                                 .reportedComplete(ChunkID(1))],
                       "the queue first, in order, and then the standing script")
    }

    /// Silence is not slowness. A transfer scripted to never answer does not answer, does
    /// not land, and ends only when whoever was waiting for it stops — which is exactly what
    /// makes the driver's own timeout the thing under test.
    func testTheDoubleScriptedToNeverAnswerDoesNotAnswerUntilItsTaskIsCancelled() async throws {
        let transport = InMemoryTransportDouble(shape: .setShaped)
        await transport.scriptOnce(.neverAnswers, for: ChunkID(1))
        let session = try await transport.openSession(for: intent)

        let transfer = self.transfer(1)
        let sending = Task { try await transport.send(transfer, in: session) }
        while await !transport.calls.contains(.sent(ChunkID(1))) { await Task.yield() }

        sending.cancel()
        do {
            let outcome = try await sending.value
            XCTFail("it answered \(outcome), and it was scripted never to answer")
        } catch is CancellationError {
            // as expected: the only way out of a silence is to stop waiting for it
        }

        let held = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(held.progress, .chunks([]), "and nothing landed while it was quiet")
    }

    /// The journalling log is the in-memory log with one extra note taken, so it owes the
    /// same contract. A wrapper that dropped a record would make every ordering assertion
    /// built on it a statement about the wrapper.
    func testTheJournallingLogKeepsTheContractOfTheOneItWraps() async throws {
        try await EventLogContract.appendsMonotonicallyAndNeverAltersEarlierRecords(
            JournallingEventLog(wrapped: InMemoryEventLog(), journal: DriverJournal()))
    }

    /// The journalling transport answers exactly what the double answers, and notes only
    /// transfers. An entry for an answer the double never gave, or a missing one, would make
    /// the interleaving a fiction.
    func testTheJournallingTransportAnswersExactlyWhatTheOneItWrapsAnswers() async throws {
        let double = InMemoryTransportDouble(shape: .setShaped)
        await double.script(.refuse, for: ChunkID(2))
        let journal = DriverJournal()
        let transport = JournallingTransport(wrapped: double, journal: journal)

        let session = try await transport.openSession(for: intent)
        let first = try await transport.send(transfer(1), in: session)
        let second = try await transport.send(transfer(2), in: session)
        let held = try await transport.confirmedProgress(in: session)

        XCTAssertEqual(first, .reportedComplete(ChunkID(1)))
        XCTAssertEqual(second, .refused(ChunkID(2)))
        XCTAssertEqual(held.progress, .chunks([ChunkID(1)]),
                       "the authority behind the wrapper is the one that was asked")
        let entries = await journal.entries
        XCTAssertEqual(entries, [.sent(ChunkID(1)), .sent(ChunkID(2))],
                       "transfers are noted, and nothing else is")
    }
}
