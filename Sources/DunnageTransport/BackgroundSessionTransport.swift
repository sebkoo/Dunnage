import DunnageCore

/// The transport that leaves the process: part PUTs go over a background session, whose
/// tasks the daemon keeps across relaunch, and this actor is what the next process uses
/// to find them again.
///
/// It owns a registry of the tasks it has named — one per `(session, chunk)` (ADR-0007
/// §4) — and nothing else about them. This commit gives it the registry and `adopt()`;
/// `UploadTransport` conformance, the control-plane calls and the completion listener
/// follow in their own commits.
///
/// A task is registered only under a description this transport can read as its own. One
/// it cannot read is cancelled and never registered, because a task that is not ours is
/// not evidence about any upload — "progress" it might seem to show is a string somebody
/// else wrote.
public actor BackgroundSessionTransport {
    private let tasks: any PartTaskSession
    private let chunkFiles: ChunkFiles

    /// The tasks this transport has named, by name. Keyed by the decoded description, so
    /// a key exists only for a task that decoded.
    private var inFlight: [TaskDescription: PartTaskID] = [:]

    public init(tasks: any PartTaskSession, chunkFiles: ChunkFiles) {
        self.tasks = tasks
        self.chunkFiles = chunkFiles
    }

    /// Adopt the tasks the daemon still holds. Explicit and once, before any send: the
    /// registry is what a `send` consults before creating a task, and a send that ran
    /// before adoption would create a second task for a chunk that already has one.
    ///
    /// A pending task whose description decodes is registered under it; one whose
    /// description does not is cancelled and never registered. A second call re-reads and
    /// re-registers, and cancels nothing it already holds — what it holds decoded once and
    /// decodes again.
    public func adopt() async {
        for pending in await tasks.pendingTasks() {
            if let description = TaskDescription(decoding: pending.description) {
                inFlight[description] = pending.id
            } else {
                await tasks.cancel(pending.id)
            }
        }
    }

    /// The chunks of `upload` with a registered task.
    public func inFlightChunks(of upload: UploadID) -> Set<ChunkID> {
        Set(inFlight.keys.filter { $0.upload == upload }.map(\.chunk))
    }
}
