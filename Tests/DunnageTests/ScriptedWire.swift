import Foundation
import DunnageCore
@testable import DunnageTransport

/// The daemon and the wire, together, as a double.
///
/// It implements `PartTaskSession` — this repository's contract — and never `URLSession`:
/// a double of a vendor's product runs a guess against itself (ADR-0007 §9), and what a
/// test on this double establishes is what the transport does with the answers the
/// contract allows, not what the daemon would have done.
///
/// Tasks are held in creation order and their ids minted 1, 2, 3, … in the order minted.
/// `seedPending` is a task "the daemon still holds" from a previous process: it is not a
/// call the transport made, so it is not in the journal. `completions` is one stream for
/// the double's lifetime, and the test drives it through `complete(_:with:)`. A receipt
/// is counted per `createTask` whose description names a part; one that does not parse
/// names nothing, so it counts nothing.
actor ScriptedWire: PartTaskSession {

    /// Every call the transport made, in order.
    enum Call: Hashable, Sendable {
        case pendingTasks
        case createTask(description: String)
        case cancel(PartTaskID)
    }

    private(set) var journal: [Call] = []
    nonisolated let completions: AsyncStream<TaskCompletion>

    private let continuation: AsyncStream<TaskCompletion>.Continuation
    private var held: [PendingTask] = []
    private var nextID = 1
    private var receipts: [Int: Int] = [:]

    init() {
        (completions, continuation) = AsyncStream<TaskCompletion>.makeStream()
    }

    // MARK: scripting

    /// A task the daemon still holds from a previous process, under this description.
    func seedPending(description: String) -> PartTaskID {
        mint(description)
    }

    /// Deliver one completion, in the order these calls are made.
    func complete(_ id: PartTaskID, with completion: PartTaskCompletion) {
        continuation.yield(TaskCompletion(id: id, completion: completion))
    }

    /// How many tasks were created whose description names this part.
    func puts(part: Int) -> Int {
        receipts[part] ?? 0
    }

    // MARK: PartTaskSession

    func pendingTasks() async -> [PendingTask] {
        journal.append(.pendingTasks)
        return held
    }

    func createTask(description: String, file: URL, url: URL) async throws -> PartTaskID {
        journal.append(.createTask(description: description))
        if let named = TaskDescription(decoding: description) {
            receipts[named.chunk.ordinal, default: 0] += 1
        }
        return mint(description)
    }

    func cancel(_ id: PartTaskID) async {
        journal.append(.cancel(id))
        held.removeAll { $0.id == id }
    }

    private func mint(_ description: String) -> PartTaskID {
        let id = PartTaskID(nextID)
        nextID += 1
        held.append(PendingTask(id: id, description: description))
        return id
    }
}
