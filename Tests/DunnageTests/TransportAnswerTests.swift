import XCTest
import DunnageCore
@testable import DunnageTransport

/// What a session reported is an answer the driver received, and confirmed progress comes
/// only from what the authority holds.
///
/// ADR-0007 §5: the completion listener maps each completion to exactly one
/// `TransferOutcome` and hands it to the sends awaiting that task; a completion no send
/// was awaiting is held in memory for the first send that asks and never reaches the log.
/// ADR-0007 §7: a chunk file is deleted when `/parts` confirms the chunk, not when a
/// completion reports it. Deterministic, on the scripted wire and a canned plane: a test
/// that waits for a send to reach its await awaits the transport's own count of the
/// waiters it has stored, and one that waits for a send to leave it awaits the send's own
/// `Task`; nothing here waits on a clock and nothing counts yields.
final class TransportAnswerTests: XCTestCase {

    /// The requests the plane was asked and the answers it gives back, local to the test
    /// that made the closure. `held` is what `/parts` reports — the authority's own set,
    /// which a test moves when the authority is meant to have taken a part — and
    /// `complete` is what the complete route answers.
    private actor PlaneJournal {
        private(set) var requests: [PlaneRequest] = []
        private var held: [Int] = []
        private var complete = PlaneResponse(status: 200, body: Data(#"{"etag":"e"}"#.utf8))

        func hold(_ parts: [Int]) { held = parts }
        func answerComplete(with response: PlaneResponse) { complete = response }

        /// Record the request and answer it as the route it names. Five parts are signed
        /// for any `/urls`, because the fixture's plan has five.
        func answer(_ request: PlaneRequest) -> PlaneResponse {
            requests.append(request)
            if request.path.hasSuffix("/urls") {
                let entries = (1...5).map { #"{"partNumber":\#($0),"url":"https://x/\#($0)"}"# }
                return PlaneResponse(status: 200,
                                     body: Data(#"{"urls":[\#(entries.joined(separator: ","))]}"#.utf8))
            }
            if request.path.hasSuffix("/parts") {
                let numbers = held.map(String.init).joined(separator: ",")
                return PlaneResponse(status: 200, body: Data(#"{"parts":[\#(numbers)]}"#.utf8))
            }
            if request.path.hasSuffix("/complete") { return complete }
            return PlaneResponse(status: 200, body: Data(#"{"uploadId":"u"}"#.utf8))
        }
    }

    /// How a send that ran as a `Task` ended. An enum and not a `Result`, so that what a
    /// send returned is compared whole in one assertion and a thrown error is still
    /// readable in the failure.
    private enum Ending: Hashable, Sendable {
        case outcome(TransferOutcome)
        case threw(String)
    }

    /// How the sends ended, by the chunk they were for.
    private actor Sends {
        private(set) var ended: [ChunkID: Ending] = [:]
        func record(_ chunk: ChunkID, _ ending: Ending) { ended[chunk] = ending }
    }

    private struct Fixture {
        let transport: BackgroundSessionTransport
        let wire: ScriptedWire
        let chunkFiles: ChunkFiles
        let intent: UploadIntent
        let session = TransportSessionID("r/u")

        func transfer(_ ordinal: Int) -> PlannedTransfer {
            let chunk = ChunkID(ordinal)
            return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
        }

        func description(_ ordinal: Int) -> TaskDescription {
            TaskDescription(upload: intent.upload, session: session, chunk: ChunkID(ordinal))
        }
    }

    /// Upload `a` to ref `r`: 20 bytes cut in fours, so the plan has five chunks and every
    /// `urls` request signs five parts.
    private func fixture(plane: PlaneJournal) throws -> Fixture {
        let root = try temporaryDirectory()
        let support = root.appendingPathComponent("support", isDirectory: true)
        let ref = PayloadRef("payloads/a")
        let file = support.appendingPathComponent(ref.rawValue)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<20).map { UInt8($0) }).write(to: file)

        let intent = UploadIntent(upload: UploadID("a"),
                                  destination: DestinationRef("r"),
                                  payload: ref,
                                  plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
        let chunkFiles = ChunkFiles(directory: root.appendingPathComponent("chunks", isDirectory: true),
                                    resolve: { support.appendingPathComponent($0.rawValue) })
        let wire = ScriptedWire()
        let transport = BackgroundSessionTransport(
            plane: CannedPlane { await plane.answer($0) }, tasks: wire, chunkFiles: chunkFiles)
        return Fixture(transport: transport, wire: wire, chunkFiles: chunkFiles, intent: intent)
    }

    /// Run one send as a `Task` and record how it ended, so a test can await the `Task`
    /// and then read what it returned.
    private func start(_ ordinal: Int, of f: Fixture, into sends: Sends) -> Task<Void, Never> {
        Task {
            let chunk = ChunkID(ordinal)
            do {
                let outcome = try await f.transport.send(f.transfer(ordinal), of: f.intent, in: f.session)
                await sends.record(chunk, .outcome(outcome))
            } catch {
                await sends.record(chunk, .threw(String(describing: error)))
            }
        }
    }

    /// Cancel a send and wait for it to let go, so nothing outlives the test. A no-op once
    /// the send has already returned; in a run where a waiter was never resumed, this is
    /// what lets it go and the failure above names itself.
    private func release(_ send: Task<Void, Never>) async {
        send.cancel()
        await send.value
    }

    /// Start a send for `ordinal` and wait until it has registered a waiter on its task,
    /// so the task exists under its description and the id the wire minted for it is known.
    ///
    /// `registration` is cumulative — the transport counts every waiter it has stored for
    /// the chunk, never the live count — so a second send for a chunk one send has already
    /// waited on asks for the second.
    private func awaiting(_ ordinal: Int, registration: Int = 1,
                          of f: Fixture, into sends: Sends) async -> Task<Void, Never> {
        let send = start(ordinal, of: f, into: sends)
        await f.transport.whenRegistered(registration, on: ChunkID(ordinal), of: f.intent.upload)
        return send
    }

    // MARK: claim 3

    /// The mapping, ADR-0007 §5's table: a 2xx is a report, any other status is a refusal,
    /// and no answer at all is an interruption. Three sends are started one after another,
    /// so the wire mints ids 1, 2 and 3 for chunks 1, 2 and 3 and each completion names the
    /// task the test means. A claimed completion also leaves the registry, so nothing is in
    /// flight when the three have been answered.
    func testEachCompletionBecomesTheOneOutcomeThatMeansIt() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        let sends = Sends()
        var running: [Task<Void, Never>] = []
        for ordinal in 1...3 { running.append(await awaiting(ordinal, of: f, into: sends)) }

        await f.transport.deliver(TaskCompletion(id: PartTaskID(1), completion: .answered(status: 200)))
        await f.transport.deliver(TaskCompletion(id: PartTaskID(2), completion: .answered(status: 403)))
        await f.transport.deliver(TaskCompletion(id: PartTaskID(3), completion: .noAnswer))
        for send in running { await send.value }

        let ended = await sends.ended
        XCTAssertEqual(ended, [ChunkID(1): .outcome(.reportedComplete(ChunkID(1))),
                               ChunkID(2): .outcome(.refused(ChunkID(2))),
                               ChunkID(3): .outcome(.interrupted(ChunkID(3)))],
                       "a completion became something other than the one outcome that means it")
        let inFlight = await f.transport.inFlightChunks(of: f.intent.upload)
        XCTAssertEqual(inFlight, [], "a claimed completion left its task in the registry")
    }

    /// A completion for a task the daemon still held from a previous process, delivered
    /// while no send is awaiting it: it is held in memory, handed to the first send that
    /// asks for that chunk — which creates nothing and mints no URL — and then forgotten,
    /// so the next send for the chunk creates a task of its own. It never reaches the log,
    /// because the log records answers a driver received (ADR-0007 §5).
    func testACompletionNoSendWasAwaitingIsHandedToTheFirstSendThatAsksAndThenForgotten() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        let seeded = await f.wire.seedPending(description: f.description(2).encoded)
        await f.transport.adopt()

        await f.transport.deliver(TaskCompletion(id: seeded, completion: .answered(status: 200)))
        let unclaimed = await f.transport.unclaimedCount(ChunkID(2), of: f.intent.upload)
        XCTAssertEqual(unclaimed, 1, "a completion no send was awaiting was not held")

        let sends = Sends()
        let first = start(2, of: f, into: sends)
        await first.value

        let ended = await sends.ended
        XCTAssertEqual(ended, [ChunkID(2): .outcome(.reportedComplete(ChunkID(2)))],
                       "the first send that asked was not answered from the held completion")
        let calls = await f.wire.journal
        XCTAssertEqual(calls, [.pendingTasks],
                       "the send answered from a held completion touched the wire: \(calls)")
        let requests = await plane.requests
        XCTAssertEqual(requests, [], "the send answered from a held completion minted a URL")

        let second = await awaiting(2, of: f, into: sends)
        let puts = await f.wire.puts(part: 2)
        XCTAssertEqual(puts, 1, "the second send did not create a task of its own")
        await release(second)
    }

    /// A completion whose id is registered under no description — a task cancelled at
    /// adoption still reports — is dropped. It is not evidence about any upload, so it is
    /// held for nobody and no send is answered from it.
    ///
    /// This one cannot go red without artificial sabotage: a completion with no description
    /// names no chunk, so there is nothing a wrong implementation could do with it but
    /// drop it. It stands as the negative half of the two tests above.
    func testACompletionForATaskThisTransportDidNotNameIsDropped() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        let garbage = await f.wire.seedPending(description: "garbage")
        await f.transport.adopt()

        await f.transport.deliver(TaskCompletion(id: garbage, completion: .answered(status: 200)))

        var misbehaved: [String] = []
        for ordinal in 1...5 {
            let unclaimed = await f.transport.unclaimedCount(ChunkID(ordinal), of: f.intent.upload)
            let waiting = await f.transport.awaiting(ChunkID(ordinal), of: f.intent.upload)
            if unclaimed != 0 { misbehaved.append("chunk \(ordinal) holds \(unclaimed) completions") }
            if waiting != 0 { misbehaved.append("chunk \(ordinal) has \(waiting) waiters") }
        }
        XCTAssertEqual(misbehaved, [],
                       "a completion for a task this transport did not name was read as evidence")
        let inFlight = await f.transport.inFlightChunks(of: f.intent.upload)
        XCTAssertEqual(inFlight, [], "a task this transport did not name reached the registry")
    }

    /// The expired-URL path (ADR-0007 §6): a PUT presented with a URL that has expired is
    /// refused, 403, which is an answer and not an interruption. The claimed completion
    /// takes the task out of the registry, so the next send for that chunk creates anew and
    /// asks `/urls` again — the URL is minted at that send, and the two lives begin
    /// together (F2).
    func testAPutPresentedWithAnExpiredURLIsRefusedAndTheNextSendMintsAFreshOne() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        let sends = Sends()
        let first = await awaiting(1, of: f, into: sends)

        await f.transport.deliver(TaskCompletion(id: PartTaskID(1), completion: .answered(status: 403)))
        await first.value

        let ended = await sends.ended
        XCTAssertEqual(ended, [ChunkID(1): .outcome(.refused(ChunkID(1)))],
                       "a PUT the authority refused was not read as a refusal")
        let inFlight = await f.transport.inFlightChunks(of: f.intent.upload)
        XCTAssertEqual(inFlight, [], "the refused task stayed in the registry")

        let second = await awaiting(1, registration: 2, of: f, into: sends)
        let requests = await plane.requests
        XCTAssertEqual(requests, [ControlPlaneWire.urls(ref: "r", uploadId: "u", parts: 5),
                                  ControlPlaneWire.urls(ref: "r", uploadId: "u", parts: 5)],
                       "the send after the refusal did not mint a fresh URL")
        let calls = await f.wire.journal
        XCTAssertEqual(calls, [.createTask(description: f.description(1).encoded),
                               .start(PartTaskID(1)),
                               .createTask(description: f.description(1).encoded),
                               .start(PartTaskID(2))],
                       "the send after the refusal did not create a task of its own: \(calls)")
        let puts = await f.wire.puts(part: 1)
        XCTAssertEqual(puts, 2, "part 1 was not presented exactly twice")
        await release(second)
    }

    /// Three completions reported, and the authority holds two of them. Confirmed progress
    /// is the authority's answer and nothing else: `/parts` is asked once, and what the
    /// session reported does not widen it. The confirmation names the upload and the
    /// transport operation it was asked with, so it can never be applied to another.
    func testConfirmedProgressComesOnlyFromWhatTheAuthorityHolds() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        let sends = Sends()
        var running: [Task<Void, Never>] = []
        for ordinal in 1...3 { running.append(await awaiting(ordinal, of: f, into: sends)) }
        for id in 1...3 {
            await f.transport.deliver(TaskCompletion(id: PartTaskID(id), completion: .answered(status: 200)))
        }
        for send in running { await send.value }
        await plane.hold([1, 2])

        let confirmation = try await f.transport.confirmedProgress(for: f.intent.upload, in: f.session)

        XCTAssertEqual(confirmation, Confirmation(upload: f.intent.upload, session: f.session,
                                                  progress: .chunks([ChunkID(1), ChunkID(2)])),
                       "confirmed progress is not what the authority holds, named for what it was asked with")
        let requests = await plane.requests
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/parts") },
                       [ControlPlaneWire.parts(ref: "r", uploadId: "u")],
                       "the authority was not asked exactly once for what it holds")
    }

    /// `finalize` asks the plane to complete the object, and the one refusal it can name is
    /// named: the stand-in's 400 for a complete over parts it does not hold becomes
    /// `TransportError.incompleteUpload`, which is not the same fact as a malformed
    /// request.
    func testFinalizeAsksThePlaneToCompleteAndAnIncompleteRefusalIsNamed() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)

        try await f.transport.finalize(f.session)

        let requests = await plane.requests
        XCTAssertEqual(requests, [ControlPlaneWire.complete(ref: "r", uploadId: "u")],
                       "finalize did not ask the complete route exactly once")

        let refusing = PlaneJournal()
        await refusing.answerComplete(with: PlaneResponse(status: 400,
                                                          body: Data(#"{"error":"incomplete upload"}"#.utf8)))
        let g = try fixture(plane: refusing)
        do {
            try await g.transport.finalize(g.session)
            XCTFail("a complete over parts the authority does not hold returned")
        } catch let error as TransportError {
            XCTAssertEqual(error, .incompleteUpload,
                           "the stand-in's refusal of an incomplete complete was not named")
        }
    }

    /// The one test that goes through the session: a completion the wire delivers on its
    /// own stream reaches the send that is awaiting it. Every other test here calls
    /// `deliver` directly, so without this one the `Task` `adopt()` starts could be deleted
    /// and the suite would stay green.
    func testTheListenerAdoptionStartsDeliversWhatTheSessionReports() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        await f.transport.adopt()

        let sends = Sends()
        let send = start(1, of: f, into: sends)
        // Both events, in the order the transport performs them: the wire starts the task,
        // and the send then registers a waiter on it. A completion delivered before the
        // registration would be held for a send that had not yet committed to waiting.
        let started = await f.wire.nextStart()
        await f.transport.whenRegistered(1, on: ChunkID(1), of: f.intent.upload)

        await f.wire.complete(started, with: .answered(status: 200))
        await send.value

        let ended = await sends.ended
        XCTAssertEqual(ended, [ChunkID(1): .outcome(.reportedComplete(ChunkID(1)))],
                       "what the session reported did not reach the send awaiting it")
    }

    /// A task is registered before it is started, so a completion can never arrive for a
    /// task this transport has not yet named.
    ///
    /// The wire reports this task's completion the instant it is started — the earliest a
    /// session can say anything about a task. A transport that started the task before
    /// recording its id would be handed a completion naming an id it could not resolve,
    /// would drop it as not its own, and would then register a task that had already
    /// ended: the send waits for an answer that has been and gone, and every later send
    /// for the chunk adopts the dead entry. Ordering is what removes that, not a rule
    /// about what to do afterwards.
    func testACompletionCannotArriveForATaskThisTransportHasNotYetNamed() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        await f.transport.adopt()
        await f.wire.completeOnStart(.answered(status: 200))

        let sends = Sends()
        let send = start(1, of: f, into: sends)
        await send.value

        let ended = await sends.ended
        XCTAssertEqual(ended, [ChunkID(1): .outcome(.reportedComplete(ChunkID(1)))],
                       "a completion the session reported at the start of the task did not reach the send")
        let calls = await f.wire.journal
        XCTAssertEqual(calls, [.pendingTasks,
                               .createTask(description: f.description(1).encoded),
                               .start(PartTaskID(1))],
                       "the task was not created, then started, exactly once: \(calls)")
        let unclaimed = await f.transport.unclaimedCount(ChunkID(1), of: f.intent.upload)
        XCTAssertEqual(unclaimed, 0, "the completion was held rather than handed to the send waiting for it")
    }

    // MARK: claim 5

    /// A chunk file is deleted when the authority confirms the chunk, not when a completion
    /// reports it (ADR-0007 §7). Three sends write three files; a completion reports chunk
    /// 1 and all three files are still there, because a report is an observation about a
    /// request. Then the authority says it holds 1 and 2, and those two files are gone.
    func testAChunkFileIsDiscardedWhenTheAuthorityConfirmsTheChunkNotWhenACompletionReports() async throws {
        let plane = PlaneJournal()
        let f = try fixture(plane: plane)
        let sends = Sends()
        var running: [Task<Void, Never>] = []
        for ordinal in 1...3 { running.append(await awaiting(ordinal, of: f, into: sends)) }

        await f.transport.deliver(TaskCompletion(id: PartTaskID(1), completion: .answered(status: 200)))
        await running[0].value          // the send for chunk 1, the one this completion answers
        XCTAssertEqual(try f.chunkFiles.present(for: f.intent.upload),
                       [ChunkID(1), ChunkID(2), ChunkID(3)],
                       "a chunk file was deleted when a completion reported it")

        await plane.hold([1, 2])
        _ = try await f.transport.confirmedProgress(for: f.intent.upload, in: f.session)

        XCTAssertEqual(try f.chunkFiles.present(for: f.intent.upload), [ChunkID(3)],
                       "the files of the chunks the authority confirmed were not deleted")
        for send in running { await release(send) }
    }
}
