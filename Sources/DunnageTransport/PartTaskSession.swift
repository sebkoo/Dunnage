import Foundation

/// The identity of one background upload task, as the session that holds it names it.
public struct PartTaskID: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

/// A task the daemon still holds, with the description it was created under. The
/// description is the one string the system persists with a task across relaunch
/// (ADR-0007 §4), and it is all this transport has to say whose task it is.
public struct PendingTask: Hashable, Sendable {
    public let id: PartTaskID
    public let description: String
    public init(id: PartTaskID, description: String) {
        self.id = id
        self.description = description
    }
}

/// How one task ended, as the session reports it. `answered` carries the status the
/// authority gave; `noAnswer` is an error in place of one — the connection dropped, the
/// task was cancelled, the daemon gave up. The mapping to a `TransferOutcome` is the
/// transport's (ADR-0007 §5), not the session's.
public enum PartTaskCompletion: Hashable, Sendable {
    case answered(status: Int)
    case noAnswer
}

/// One task's completion, named by the task it belongs to.
public struct TaskCompletion: Hashable, Sendable {
    public let id: PartTaskID
    public let completion: PartTaskCompletion
    public init(id: PartTaskID, completion: PartTaskCompletion) {
        self.id = id
        self.completion = completion
    }
}

/// The session that holds part-upload tasks on the transport's behalf: the daemon and the
/// wire, behind one contract this repository states.
///
/// The production implementation is a background `URLSession` behind this contract, in
/// this module — `URLSessionPartTasks`, a later commit's, which the app constructs with
/// the configuration ADR-0007 §6 names. The test target's double implements this contract,
/// never `URLSession` (ADR-0007 §9's rule: a double of a vendor's product runs a guess
/// against itself).
///
/// `completions` is a stream for this process's lifetime: a completion for a task the
/// previous process created arrives here after relaunch, and what the transport does with
/// one no `send` is awaiting is ADR-0007 §5's.
public protocol PartTaskSession: Sendable {
    /// What the daemon still holds — created by this process or a previous one.
    func pendingTasks() async -> [PendingTask]

    /// Create an upload task for `file` against `url`, persisted under `description`.
    func createTask(description: String, file: URL, url: URL) async throws -> PartTaskID

    /// Cancel a task. The daemon stops it and forgets it.
    func cancel(_ id: PartTaskID) async

    /// Every completion this process sees, in the order the session delivered them.
    var completions: AsyncStream<TaskCompletion> { get }
}
