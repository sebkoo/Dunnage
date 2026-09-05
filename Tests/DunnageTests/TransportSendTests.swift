import XCTest
import DunnageCore
@testable import DunnageTransport

/// A chunk has at most one transfer in flight, and a send for a chunk already in flight
/// waits on it rather than starting another.
///
/// ADR-0007 §4: a `send` looks for an adopted or created task for `(session, chunk)`; if
/// one is in flight it awaits that task and does not create another. The driver's timeout
/// cancels the await, never the task. Deterministic, on the scripted wire and a canned
/// plane: a test that waits for a concurrent send to reach a point awaits the event that
/// takes it there — the wire's next start, or the transport's own count of the waiters it
/// has stored — so nothing here waits on a clock and nothing counts yields. Nothing
/// resumes a waiter with an outcome yet — the completion listener is a later commit's —
/// so every send here is cancelled at the end, and its await throws `CancellationError`.
final class TransportSendTests: XCTestCase {

    /// The requests the plane was asked, local to the test that made the closure.
    private actor PlaneJournal {
        private(set) var requests: [PlaneRequest] = []
        func record(_ request: PlaneRequest) { requests.append(request) }
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
    private func fixture(plane: CannedPlane) throws -> Fixture {
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
        let transport = BackgroundSessionTransport(plane: plane, tasks: wire, chunkFiles: chunkFiles)
        return Fixture(transport: transport, wire: wire, chunkFiles: chunkFiles, intent: intent)
    }

    /// The urls route's answer for `parts` parts: `https://x/<n>` for each.
    private func signed(parts: Int) -> PlaneResponse {
        let entries = (1...parts).map { #"{"partNumber":\#($0),"url":"https://x/\#($0)"}"# }
        return PlaneResponse(status: 200, body: Data(#"{"urls":[\#(entries.joined(separator: ","))]}"#.utf8))
    }

    /// A plane that journals every request and signs five parts for any of them.
    private func signingPlane(_ journal: PlaneJournal) -> CannedPlane {
        CannedPlane { [signed = signed(parts: 5)] request in
            await journal.record(request)
            return signed
        }
    }

    /// A gate the test opens: the canned plane's closure waits on it, so a send can be held
    /// inside `/urls` while a second send arrives. The test's own, captured by its closure.
    private actor Latch {
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            opened = true
            for continuation in waiting { continuation.resume() }
            waiting = []
        }
    }

    /// Cancel a send and wait for its await to let go, so nothing outlives the test.
    private func release(_ send: Task<TransferOutcome, any Error>) async {
        send.cancel()
        _ = await send.result
    }

    // MARK: claim 2

    /// `openSession` asks `POST /uploads` once, with the destination and the plan's chunk
    /// count, and the identity it hands Core is `<ref>/<uploadId>` from the answer.
    func testOpenSessionAsksThePlaneOnceAndComposesTheIdentityFromItsAnswer() async throws {
        let journal = PlaneJournal()
        let f = try fixture(plane: CannedPlane { request in
            await journal.record(request)
            return PlaneResponse(status: 200, body: Data(#"{"uploadId":"u"}"#.utf8))
        })

        let session = try await f.transport.openSession(for: f.intent)

        let requests = await journal.requests
        XCTAssertEqual(requests, [ControlPlaneWire.create(ref: "r", parts: 5)],
                       "openSession did not ask the create route exactly once")
        XCTAssertEqual(session, TransportSessionID("r/u"),
                       "the identity is not composed from the plane's uploadId")
    }

    /// One send for chunk 1: one `urls` request signing the plan's five parts, one task
    /// created under the chunk's description, one receipt for part 1, and the chunk file
    /// written. The URL is minted at send (ADR-0007 §6, F2).
    func testASendMintsItsURLAtSendAndCreatesOneTaskNamedForTheChunk() async throws {
        let journal = PlaneJournal()
        let f = try fixture(plane: signingPlane(journal))
        let created = ScriptedWire.Call.createTask(description: f.description(1).encoded)

        let send = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        _ = await f.wire.nextStart()

        let requests = await journal.requests
        XCTAssertEqual(requests, [ControlPlaneWire.urls(ref: "r", uploadId: "u", parts: 5)],
                       "the URL was not minted at send by one urls request for the plan's parts")
        let calls = await f.wire.journal
        XCTAssertEqual(calls, [created, .start(PartTaskID(1))],
                       "the wire saw something other than one task named for chunk 1, created then started")
        let puts = await f.wire.puts(part: 1)
        XCTAssertEqual(puts, 1, "part 1 was not created exactly once")
        XCTAssertEqual(try f.chunkFiles.present(for: f.intent.upload), [ChunkID(1)],
                       "the chunk file for chunk 1 was not written at send")

        await release(send)
    }

    /// Two sends for chunk 1 at once: both end up waiting on one task, and the wire and
    /// the plane each saw exactly one request for it.
    func testAChunkHasAtMostOneTransferInFlightWhenTwoSendsRace() async throws {
        let journal = PlaneJournal()
        let f = try fixture(plane: signingPlane(journal))

        let first = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        let second = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        await f.transport.whenRegistered(2, on: ChunkID(1), of: f.intent.upload)

        let calls = await f.wire.journal
        XCTAssertEqual(calls, [.createTask(description: f.description(1).encoded), .start(PartTaskID(1))],
                       "two sends that raced did not create exactly one task")
        let requests = await journal.requests
        XCTAssertEqual(requests, [ControlPlaneWire.urls(ref: "r", uploadId: "u", parts: 5)],
                       "two sends that raced did not mint exactly one URL")

        await release(first)
        await release(second)
    }

    /// A task for chunk 2 the daemon still holds is adopted; a send for chunk 2 then waits
    /// on it — no task created, no URL minted, no receipt.
    func testASendForAChunkAlreadyInFlightWaitsOnItRatherThanStartingAnother() async throws {
        let journal = PlaneJournal()
        let f = try fixture(plane: signingPlane(journal))
        _ = await f.wire.seedPending(description: f.description(2).encoded)
        await f.transport.adopt()

        let send = Task { try await f.transport.send(f.transfer(2), of: f.intent, in: f.session) }
        await f.transport.whenRegistered(1, on: ChunkID(2), of: f.intent.upload)

        let calls = await f.wire.journal
        XCTAssertEqual(calls, [.pendingTasks], "a send for a chunk already in flight touched the wire")
        let requests = await journal.requests
        XCTAssertEqual(requests, [], "a send for a chunk already in flight minted a URL")
        let puts = await f.wire.puts(part: 2)
        XCTAssertEqual(puts, 0, "a send for a chunk already in flight created a task")

        await release(send)
    }

    /// The injected fault is the cancelled await — what the driver's timeout does. The
    /// send's Task is cancelled: its await throws `CancellationError`, the daemon's task
    /// is not cancelled, the chunk stays in flight, and a second send for it creates
    /// nothing.
    func testAnAwaitCancelledMidTransferLeavesTheTaskRunningAndASecondSendCreatesNothing() async throws {
        let journal = PlaneJournal()
        let f = try fixture(plane: signingPlane(journal))

        let first = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        _ = await f.wire.nextStart()
        first.cancel()
        switch await first.result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "the cancelled await threw \(error), not CancellationError")
        case .success(let outcome):
            XCTFail("the cancelled await returned an outcome: \(outcome)")
        }

        let calls = await f.wire.journal
        XCTAssertFalse(calls.contains { if case .cancel = $0 { true } else { false } },
                       "cancelling the await cancelled the task: \(calls)")
        let inFlight = await f.transport.inFlightChunks(of: f.intent.upload)
        XCTAssertEqual(inFlight, [ChunkID(1)], "the chunk left flight with the await")
        let stillWaiting = await f.transport.awaiting(ChunkID(1), of: f.intent.upload)
        XCTAssertEqual(stillWaiting, 0, "the cancelled await left its waiter behind")

        let second = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        // Two, cumulatively: the cancelled await stored a waiter of its own before the
        // cancellation removed it, and this is the send that follows it.
        await f.transport.whenRegistered(2, on: ChunkID(1), of: f.intent.upload)
        let puts = await f.wire.puts(part: 1)
        XCTAssertEqual(puts, 1, "a second send after the cancelled await created another task")

        await release(second)
    }

    /// The injected fault is a creation that fails while a second send is already waiting
    /// on it. Send 1 is held inside `/urls` by a latch; send 2 arrives, finds the creating
    /// mark, and stores a waiter; the latch opens with 403. A waiter must always have a
    /// task or an error — a waiter on a creation that failed waits on nothing — so both
    /// sends end with the same refusal, nothing was created, and nothing is in flight.
    func testWaitersOnAChunkWhoseCreationFailedAreResumedWithTheFailure() async throws {
        let latch = Latch()
        let f = try fixture(plane: CannedPlane { _ in
            await latch.wait()
            return PlaneResponse(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8))
        })

        let first = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        let second = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        await f.transport.whenRegistered(1, on: ChunkID(1), of: f.intent.upload)

        await latch.open()
        // Both sends end of their own accord — the first on the refusal it was thrown, the
        // second on the drain that refusal performs — and the cancel is a no-op by then. In
        // a run where the waiter was never resumed, this is what lets it go, so nothing
        // outlives the test and the assertions below name themselves.
        await release(first)
        await release(second)

        for (which, result) in [("first", await first.result), ("second", await second.result)] {
            switch result {
            case .failure(let error as ControlPlaneError) where error == .refused(status: 403):
                continue
            default:
                XCTFail("the \(which) send ended with \(result), not the plane's refusal")
            }
        }
        let calls = await f.wire.journal
        XCTAssertFalse(calls.contains { if case .createTask = $0 { true } else { false } },
                       "a task was created for a chunk whose URL was refused: \(calls)")
        let inFlight = await f.transport.inFlightChunks(of: f.intent.upload)
        XCTAssertEqual(inFlight, [], "a chunk whose creation failed is still in flight")
        let waiting = await f.transport.awaiting(ChunkID(1), of: f.intent.upload)
        XCTAssertEqual(waiting, 0, "a waiter is still waiting on a creation that failed")
    }

    /// A registration wait returns only once the waiter it counted is observable.
    ///
    /// Every other wait in these three files leans on this: `whenRegistered` resumes from
    /// inside `store(_:for:ticket:)`, where the waiter comes to exist, so a send that has
    /// been counted is a send `awaiting(_:of:)` can see. An implementation that counted at
    /// the call site in `send` — before the URL is minted and the task created — would
    /// return here with nothing stored.
    ///
    /// What it cannot cover: an affordance that never resumes at all is a hang and not a
    /// red, and the only backstop for that is the job's own bound (ADR-0007 O-17).
    func testARegistrationWaitReturnsOnlyOnceTheWaiterItCountsIsObservable() async throws {
        let journal = PlaneJournal()
        let f = try fixture(plane: signingPlane(journal))

        let send = Task { try await f.transport.send(f.transfer(1), of: f.intent, in: f.session) }
        await f.transport.whenRegistered(1, on: ChunkID(1), of: f.intent.upload)

        let waiting = await f.transport.awaiting(ChunkID(1), of: f.intent.upload)
        XCTAssertEqual(waiting, 1, "the registration wait returned before the waiter it counted existed")

        await release(send)
    }
}
