import XCTest
import DunnageCore
import DunnageDriver
@testable import DunnageTransport

/// The driver against the transport that leaves the process: a transfer outlives the wait
/// the driver gave it, and the next send is answered by the completion that arrived after
/// the driver had stopped waiting.
///
/// This is the sentence ADR-0005 §5 said the in-process double could not make. There the
/// driver stopped waiting and the double's transfer stopped with it; here the await is
/// cancelled, the task is not, and the completion the session delivers afterwards is
/// handed to the send that asks next — so one chunk is presented once, whatever the
/// driver's timeout did. Tier 1, deterministic: a virtual clock that elapses a wait only
/// when this test grants it, the scripted wire, and a canned plane. Nothing here waits on
/// wall-clock time.
final class TransportDriverTests: XCTestCase {

    /// The requests the plane was asked and the answers it gives back, local to this test.
    /// `held` is what `/parts` reports: the authority holds nothing until the completion
    /// for part 1 is delivered.
    private actor PlaneJournal {
        private(set) var requests: [PlaneRequest] = []
        private var held: [Int] = []

        func hold(_ parts: [Int]) { held = parts }

        func answer(_ request: PlaneRequest) -> PlaneResponse {
            requests.append(request)
            if request.path.hasSuffix("/urls") {
                return PlaneResponse(status: 200,
                                     body: Data(#"{"urls":[{"partNumber":1,"url":"https://x/1"}]}"#.utf8))
            }
            if request.path.hasSuffix("/parts") {
                let numbers = held.map(String.init).joined(separator: ",")
                return PlaneResponse(status: 200, body: Data(#"{"parts":[\#(numbers)]}"#.utf8))
            }
            if request.path.hasSuffix("/complete") {
                return PlaneResponse(status: 200, body: Data(#"{"etag":"e"}"#.utf8))
            }
            return PlaneResponse(status: 200, body: Data(#"{"uploadId":"u"}"#.utf8))
        }
    }

    /// Yield until `condition` holds, at most `bound` times; past the bound the test fails
    /// naming it. No clock: a yield is the only way the driver's own Task moves.
    private func settled(within bound: Int, _ condition: () async -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async {
        var yields = 0
        var holds = await condition()
        while !holds, yields < bound {
            await Task.yield()
            yields += 1
            holds = await condition()
        }
        XCTAssertTrue(holds, "not settled within \(bound) yields", file: file, line: line)
    }

    /// One chunk, one task, and a driver whose wait is granted exactly once.
    ///
    /// The granted wait is the first transfer's timeout, so the driver stops waiting and
    /// records `chunkTransferInterrupted` — the absence of an answer, not a claim about the
    /// bytes. It then asks the authority, which holds nothing, and sends again; that second
    /// send finds the task from the first still in flight and awaits it rather than
    /// creating another. The completion arrives then, and it is the second send that
    /// receives it.
    ///
    /// The waiter this test waits for is the second send's and cannot be the first send's:
    /// a task group does not return until its children have finished, and the cancelled
    /// send finishes only when `abandon` has removed its waiter — so by the time
    /// `chunkTransferInterrupted` is on the log, the first send's waiter is gone.
    func testATransferThatOutlivesTheDriversWaitIsAnsweredByTheNextSendWithoutASecondTask() async throws {
        let root = try temporaryDirectory()
        let support = root.appendingPathComponent("support", isDirectory: true)
        let ref = PayloadRef("payloads/a")
        let file = support.appendingPathComponent(ref.rawValue)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<4).map { UInt8($0) }).write(to: file)

        let intent = UploadIntent(upload: UploadID("a"),
                                  destination: DestinationRef("r"),
                                  payload: ref,
                                  plan: ChunkPlan(totalBytes: 4, chunkSize: 4))
        let session = TransportSessionID("r/u")
        let plane = PlaneJournal()
        let wire = ScriptedWire()
        let transport = BackgroundSessionTransport(
            plane: CannedPlane { await plane.answer($0) },
            tasks: wire,
            chunkFiles: ChunkFiles(directory: root.appendingPathComponent("chunks", isDirectory: true),
                                   resolve: { support.appendingPathComponent($0.rawValue) }))
        let log = InMemoryEventLog()
        let clock = VirtualClock()
        let driver = UploadDriver(transport: transport, log: log, clock: clock,
                                  quietAfter: .seconds(30))
        func recorded() async -> [UploadEvent] {
            ((try? await log.records(for: intent.upload)) ?? []).map(\.event)
        }
        func held(_ chunks: Set<ChunkID>) -> Confirmation {
            Confirmation(upload: intent.upload, session: session, progress: .chunks(chunks))
        }

        clock.grant(.seconds(30))                    // the first transfer's timeout, once
        let run = Task { try await driver.run(intent) }
        await settled(within: 100_000) {
            let events = await recorded()
            let waiting = await transport.awaiting(ChunkID(1), of: intent.upload)
            return events.contains(.chunkTransferInterrupted(ChunkID(1))) && waiting == 1
        }

        await plane.hold([1])
        await transport.deliver(TaskCompletion(id: PartTaskID(1), completion: .answered(status: 200)))
        await settled(within: 100_000) { await UploadTransition.replay(recorded()).isTerminal }
        run.cancel()
        _ = await run.result

        let events = await recorded()
        XCTAssertEqual(events, [
            .declared(intent),
            .transportSessionOpened(session),
            .authorityReported(held([])),
            .chunkTransferInterrupted(ChunkID(1)),
            .authorityReported(held([])),
            .chunkTransferReported(ChunkID(1)),
            .authorityReported(held([ChunkID(1)])),
            .finalized,
        ], "the log is not the run this transport and this driver made together")
        XCTAssertEqual(UploadTransition.replay(events), .completed(intent: intent),
                       "the upload the log derives did not complete")

        let calls = await wire.journal
        XCTAssertEqual(calls.filter { if case .createTask = $0 { true } else { false } },
                       [.createTask(description: TaskDescription(upload: intent.upload,
                                                                 session: session,
                                                                 chunk: ChunkID(1)).encoded)],
                       "the transfer the driver stopped waiting for was started twice: \(calls)")
        let puts = await wire.puts(part: 1)
        XCTAssertEqual(puts, 1, "part 1 was presented more than once")
    }
}
