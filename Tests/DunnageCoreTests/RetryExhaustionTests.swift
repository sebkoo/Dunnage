import XCTest
import DunnageCore

/// Giving up is a decision.
///
/// `.failed` is terminal and absorbing, so nothing is allowed to drift into it. Two things
/// have to hold for that sentence to mean anything. What spends a retry budget has to be
/// stated — a refusal does, an interruption does not — and an upload that gave up has to
/// still know what the authority had confirmed when it did.
final class RetryExhaustionTests: XCTestCase {

    private let policy = RetryPolicy(maxAttemptsPerChunk: 3,
                                     initialBackoff: .milliseconds(500),
                                     maximumBackoff: .seconds(4))

    // chunks 1...5, four bytes each
    private var intent: UploadIntent {
        UploadIntent(upload: UploadID("upload-a"),
                     destination: DestinationRef("destination-a"),
                     plan: ChunkPlan(totalBytes: 20, chunkSize: 4),
                     policy: policy)
    }

    private func transfer(_ ordinal: Int) -> PlannedTransfer {
        let chunk = ChunkID(ordinal)
        return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
    }

    /// Append to the log and fold, the way a driver would. The log is what is asserted
    /// against at the end: the state has to be derivable from it and nothing else.
    @discardableResult
    private func record(_ event: UploadEvent,
                        _ log: inout [UploadEvent],
                        _ state: inout UploadMachineState,
                        _ context: String,
                        file: StaticString = #filePath, line: UInt = #line) -> [UploadEffect] {
        log.append(event)
        guard case .accepted(let next, let effects) = UploadTransition.apply(event, to: state)
        else {
            XCTFail("\(context): \(event) was rejected in \(state.phase.rawValue)",
                    file: file, line: line)
            return []
        }
        state = next
        return effects
    }

    /// Chunks 1, 2 and 4 land and are confirmed; 3 and 5 are what is left. Then chunk 3 is
    /// refused, round after round, while chunk 5 is interrupted just as often.
    ///
    /// The refusals spend a budget and the interruptions spend nothing. When the budget is
    /// gone the machine does not become `.failed` — it asks the authority one last time and
    /// then asks the driver to give up, which is what makes the entry a decision. What the
    /// authority confirmed is still on the log, still in the state, and still enough to
    /// derive exactly the two chunks that never landed.
    func testRetryExhaustion_IsADecisionThatPreservesConfirmedProgress() async throws {
        let intent = self.intent
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        await transport.script(.refuse, for: ChunkID(3))
        await transport.script(.stall, for: ChunkID(5))

        var log: [UploadEvent] = [.declared(intent), .transportSessionOpened(session)]
        var state = UploadTransition.replay(log)

        for ordinal in [1, 2, 4] {
            _ = try await transport.send(transfer(ordinal), in: session)
            record(.chunkTransferReported(ChunkID(ordinal)), &log, &state, "opening round")
        }
        let held = try await transport.confirmedProgress(in: session)
        XCTAssertEqual(held.progress, .chunks([ChunkID(1), ChunkID(2), ChunkID(4)]),
                       "three of five chunks are what the authority holds")
        var scheduled = record(.authorityReported(held), &log, &state, "opening round")
        XCTAssertEqual(scheduled, [.send([transfer(3), transfer(5)], session, after: .zero)],
                       "nothing has been refused yet, so the first send does not wait")

        for round in 1...policy.maxAttemptsPerChunk {
            let context = "round \(round)"

            let refusal = try await transport.send(transfer(3), in: session)
            let interruption = try await transport.send(transfer(5), in: session)
            XCTAssertEqual(refusal, .refused(ChunkID(3)), context)
            XCTAssertEqual(interruption, .interrupted(ChunkID(5)), context)

            let afterInterruption =
                record(.chunkTransferInterrupted(ChunkID(5)), &log, &state, context)
            let afterRefusal =
                record(.chunkTransferRefused(ChunkID(3)), &log, &state, context)

            for (what, effects) in [("an interruption", afterInterruption),
                                    ("a refusal", afterRefusal)] {
                XCTAssertEqual(effects,
                               [.askAuthorityForConfirmedProgress(intent.upload, session)],
                               "\(context): \(what) sends Core to the authority, and nothing else")
            }
            XCTAssertEqual(state.phase, .transferring,
                           "\(context): spending a retry is not by itself a failure")

            scheduled = record(.authorityReported(held), &log, &state, context)

            if round < policy.maxAttemptsPerChunk {
                XCTAssertEqual(
                    scheduled,
                    [.send([transfer(3), transfer(5)], session,
                           after: policy.backoff(beforeAttempt: round + 1))],
                    "\(context): the budget is not gone, so the two outstanding chunks go again")
            } else {
                XCTAssertEqual(scheduled, [.abandon(intent.upload, .retriesExhausted)],
                               "\(context): the budget is gone, so Core asks the driver to give up")
                XCTAssertEqual(state.phase, .transferring,
                               "\(context): asking to give up is not the same as having given up")
            }
        }

        // ---- the decision, and only now ----
        record(.abandoned(.retriesExhausted), &log, &state, "giving up")

        guard case .failed(_, let reason, let confirmed) = state else {
            return XCTFail("an abandoned upload is failed")
        }
        XCTAssertEqual(reason, .retriesExhausted)
        XCTAssertTrue(state.isTerminal)

        // ---- and it kept what the authority had confirmed ----
        XCTAssertEqual(confirmed, held.progress,
                       "an upload that gave up threw away what the authority confirmed")
        XCTAssertEqual(ResumePlan.derive(for: intent, given: confirmed).transfers.map(\.chunk),
                       [ChunkID(3), ChunkID(5)],
                       "the chunks that never landed are still exactly derivable")
        XCTAssertEqual(UploadTransition.replay(log), state,
                       "the confirmed set has to come off the log, not out of a variable")
    }

    /// The failure mode invariant 1 names, spelled out against the budget. A network that
    /// drops every transfer produces interruptions without end, and interruptions cost
    /// nothing: no chunk is ever exhausted, and nothing waits, because nothing answered no.
    func testInterruptionsNeverSpendTheRetryBudgetHoweverManyArrive() async throws {
        let intent = self.intent
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let session = try await transport.openSession(for: intent)
        await transport.scriptEverything(.stall)

        var log: [UploadEvent] = [.declared(intent), .transportSessionOpened(session)]
        var state = UploadTransition.replay(log)
        let nothing = try await transport.confirmedProgress(in: session)
        record(.authorityReported(nothing), &log, &state, "opening round")

        let everyChunk = intent.plan.chunks.map { PlannedTransfer(chunk: $0,
                                                                  range: intent.plan.range(of: $0)!) }

        for round in 1...(policy.maxAttemptsPerChunk * 3) {
            let context = "round \(round)"
            for chunk in intent.plan.chunks {
                let outcome = try await transport.send(
                    PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!),
                    in: session)
                XCTAssertEqual(outcome, .interrupted(chunk), context)
                record(.chunkTransferInterrupted(chunk), &log, &state, context)
            }
            let scheduled = record(.authorityReported(nothing), &log, &state, context)

            XCTAssertEqual(scheduled, [.send(everyChunk, session, after: .zero)],
                           "\(context): a flaky network neither spends the budget nor earns a wait")
            XCTAssertEqual(state.phase, .transferring, "\(context): still trying")
        }
        XCTAssertFalse(state.isTerminal,
                       "\(policy.maxAttemptsPerChunk * 3) rounds of interruption ended the upload")
    }

    /// Backoff is data. Core computes how long the next attempt should wait and hands it to
    /// the driver on the effect; it never waits, never runs a timer and never reads a clock.
    func testBackoffGrowsWithEachAttemptAndIsCarriedByTheSendEffect() {
        XCTAssertEqual(policy.backoff(beforeAttempt: 1), .zero,
                       "the first attempt has nothing to wait for")
        XCTAssertEqual(policy.backoff(beforeAttempt: 2), .milliseconds(500))
        XCTAssertEqual(policy.backoff(beforeAttempt: 3), .seconds(1))
        XCTAssertEqual(policy.backoff(beforeAttempt: 4), .seconds(2))
        XCTAssertEqual(policy.backoff(beforeAttempt: 5), .seconds(4))
        XCTAssertEqual(policy.backoff(beforeAttempt: 6), .seconds(4), "capped, not doubling forever")
        XCTAssertEqual(policy.backoff(beforeAttempt: 60), .seconds(4))

        // The cap clamps even when doubling steps straight over it, which a cap that
        // happens to be a doubling of the first wait never shows.
        let overshooting = RetryPolicy(maxAttemptsPerChunk: 9,
                                       initialBackoff: .milliseconds(500),
                                       maximumBackoff: .seconds(3))
        XCTAssertEqual(overshooting.backoff(beforeAttempt: 4), .seconds(2))
        XCTAssertEqual(overshooting.backoff(beforeAttempt: 5), .seconds(3),
                       "the wait after two seconds is three, not four")
        XCTAssertEqual(overshooting.backoff(beforeAttempt: 9), .seconds(3))

        // And what the machine hands over is that same value, for the attempt the send is.
        let intent = self.intent
        let session = TransportSessionID("session-1")
        let nothing = Confirmation(upload: intent.upload, session: session, progress: .chunks([]))
        var log: [UploadEvent] = [.declared(intent), .transportSessionOpened(session),
                                  .authorityReported(nothing)]
        var state = UploadTransition.replay(log)

        for attempt in 2...policy.maxAttemptsPerChunk {
            log.append(.chunkTransferRefused(ChunkID(1)))
            state = UploadTransition.replay(log)
            log.append(.authorityReported(nothing))

            guard case .accepted(_, let effects) =
                    UploadTransition.apply(.authorityReported(nothing), to: state),
                  case .send(_, _, let wait)? = effects.first else {
                XCTFail("attempt \(attempt): the outstanding chunks are still outstanding")
                continue
            }
            state = UploadTransition.replay(log)
            XCTAssertEqual(wait, policy.backoff(beforeAttempt: attempt),
                           "attempt \(attempt): the send must carry the wait its attempt earned")
        }
    }

    /// A transport can deliver the same refusal twice, and the log cannot tell that apart
    /// from two refusals of two retries — both are two identical events. The rule that makes
    /// the fold safe is that a chunk is charged at most once between one answer from the
    /// authority and the next, which is sound because Core hands a chunk over exactly once
    /// per answer.
    ///
    /// So six refusals inside one round spend one attempt, and three spread across three
    /// rounds spend three and exhaust the budget.
    func testARefusalDeliveredTwiceBeforeTheAuthorityAnswersSpendsOneAttempt() {
        let intent = self.intent
        let session = TransportSessionID("session-1")
        let nothing = Confirmation(upload: intent.upload, session: session, progress: .chunks([]))
        let opened: [UploadEvent] = [.declared(intent), .transportSessionOpened(session),
                                     .authorityReported(nothing)]

        let hammeredInOneRound = opened
            + Array(repeating: UploadEvent.chunkTransferRefused(ChunkID(1)),
                    count: policy.maxAttemptsPerChunk * 2)
        guard case .accepted(_, let stillGoing) = UploadTransition.apply(
                .authorityReported(nothing), to: UploadTransition.replay(hammeredInOneRound)),
              case .send(_, _, let wait)? = stillGoing.first else {
            return XCTFail("one refusal delivered many times must not exhaust a budget")
        }
        XCTAssertEqual(wait, policy.backoff(beforeAttempt: 2),
                       "six deliveries of one refusal are one attempt, so the next send is the second")

        var acrossRounds = opened
        for _ in 1...policy.maxAttemptsPerChunk {
            acrossRounds.append(.chunkTransferRefused(ChunkID(1)))
            acrossRounds.append(.authorityReported(nothing))
        }
        guard case .accepted(_, let exhausted) = UploadTransition.apply(
                .authorityReported(nothing), to: UploadTransition.replay(acrossRounds)) else {
            return XCTFail("this upload's own confirmation must be applied")
        }
        XCTAssertEqual(exhausted, [.abandon(intent.upload, .retriesExhausted)],
                       "one refusal per round, for the whole budget, is what exhaustion is")
    }

    /// A refusal naming a chunk this upload never planned is not evidence about this
    /// upload, and it does not get to spend this upload's budget. It is the rule ADR-0001
    /// applies to a confirmation from another upload, one level down.
    func testARefusalNamingAChunkOutsideThisPlanSpendsNoBudget() {
        let intent = self.intent
        let session = TransportSessionID("session-1")
        let transferring = UploadTransition.replay([.declared(intent),
                                                    .transportSessionOpened(session)])

        guard case .rejected(let reason) =
                UploadTransition.apply(.chunkTransferRefused(ChunkID(99)), to: transferring) else {
            return XCTFail("a five-chunk plan has no chunk 99 to refuse")
        }
        XCTAssertEqual(reason, .chunkIsNotInThisPlan)

        // Repeating it cannot exhaust anything, because it was never charged.
        let hammered = UploadTransition.replay(
            Array(repeating: UploadEvent.chunkTransferRefused(ChunkID(99)),
                  count: policy.maxAttemptsPerChunk * 5),
            from: transferring)
        XCTAssertEqual(hammered, transferring,
                       "refusals for a chunk outside the plan moved this upload")
    }
}
