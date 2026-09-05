import XCTest
import DunnageCore
@testable import DunnageTransport

/// The contract the scripted wire owes. It stands in for `PartTaskSession`, this
/// repository's contract, and never for `URLSession` (ADR-0007 §9); a double whose
/// contract is not tested is one the suite trusts on faith. Deterministic; no session.
final class ScriptedWireContractTests: XCTestCase {

    private let named = #"{"chunk":3,"session":"r/u","upload":"a"}"#
    private let anyFile = URL(fileURLWithPath: "/chunk")
    private let anyURL = URL(string: "https://example.invalid/part")!

    /// A seeded task and a created one are what the daemon holds, in creation order with
    /// ids minted in that order; a cancelled one is gone; each call is in the journal.
    func testTheScriptedWireHoldsExactlyTheTasksCreatedOrSeededAndForgetsACancelledOne() async throws {
        let wire = ScriptedWire()
        let seeded = await wire.seedPending(description: "from a previous process")
        let created = try await wire.createTask(description: named, file: anyFile, url: anyURL)
        XCTAssertEqual([seeded, created], [PartTaskID(1), PartTaskID(2)],
                       "ids are minted 1, 2, 3, … in the order the tasks were")

        let held = await wire.pendingTasks()
        XCTAssertEqual(held, [PendingTask(id: seeded, description: "from a previous process"),
                              PendingTask(id: created, description: named)],
                       "the daemon holds exactly the seeded and created tasks, in order")

        await wire.cancel(seeded)
        let afterCancel = await wire.pendingTasks()
        XCTAssertEqual(afterCancel, [PendingTask(id: created, description: named)],
                       "a cancelled task is still held")

        let journal = await wire.journal
        XCTAssertEqual(journal, [.createTask(description: named), .pendingTasks,
                                 .cancel(seeded), .pendingTasks],
                       "the journal is not the calls the transport made, in order")
    }

    /// Complete 2, then 1: the stream yields exactly those two, in that order. The read is
    /// bounded to two elements; nothing here waits on a clock.
    func testTheScriptedWireDeliversEachCompletionOnceInTheOrderTheTestGaveThem() async {
        let wire = ScriptedWire()
        await wire.complete(PartTaskID(2), with: .answered(status: 200))
        await wire.complete(PartTaskID(1), with: .noAnswer)

        var iterator = wire.completions.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual([first, second],
                       [TaskCompletion(id: PartTaskID(2), completion: .answered(status: 200)),
                        TaskCompletion(id: PartTaskID(1), completion: .noAnswer)],
                       "the completions are not the ones given, once each, in that order")
    }

    /// Part 3 created twice and part 1 once count 2 and 1; a part never created counts 0;
    /// a description that does not parse names no part, so it counts nothing anywhere.
    func testTheScriptedWireCountsAReceiptPerTaskCreatedAndNoneForAnUnparseableOne() async throws {
        let wire = ScriptedWire()
        let partOne = #"{"chunk":1,"session":"r/u","upload":"a"}"#
        for description in [named, named, partOne, "garbage"] {
            _ = try await wire.createTask(description: description, file: anyFile, url: anyURL)
        }
        let counts = await [wire.puts(part: 3), wire.puts(part: 1), wire.puts(part: 2)]
        XCTAssertEqual(counts, [2, 1, 0],
                       "receipts for parts 3, 1 and 2 are not one per task created naming them")
        let journal = await wire.journal
        XCTAssertEqual(journal.filter { $0 == .createTask(description: "garbage") }.count, 1,
                       "the unparseable task was still created; it counts no receipt")
    }

    /// The starts are a queue and not an edge: a start made before any caller asked is
    /// still handed over, they arrive in the order they were made, and no start reaches
    /// two callers.
    ///
    /// The three starts here are all made before anybody asks, which is the case an edge
    /// loses: a signal that could be missed if a test asked a moment late would be the
    /// race the poll this replaced had, in a new shape. The last pair is the other
    /// direction — a caller that asked before the start it is handed was made.
    func testTheScriptedWireHandsOutEveryStartOnceInTheOrderItWasMade() async {
        let wire = ScriptedWire()
        await wire.start(PartTaskID(7))
        await wire.start(PartTaskID(8))
        let first = await wire.nextStart()
        await wire.start(PartTaskID(9))
        let second = await wire.nextStart()
        XCTAssertEqual([first, second], [PartTaskID(7), PartTaskID(8)],
                       "the starts were not handed out oldest first, once each")

        let waiting = Task { await wire.nextStart() }
        await wire.start(PartTaskID(10))
        let third = await waiting.value
        XCTAssertEqual(third, PartTaskID(9),
                       "the caller was not handed the start that was already waiting for one")
    }
}
