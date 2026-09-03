import Foundation
import DunnageCore

/// The transport that leaves the process: part PUTs go over a background session, whose
/// tasks the daemon keeps across relaunch, and this actor is what the next process uses
/// to find them again.
///
/// It owns a registry of the tasks it has named — one per `(session, chunk)` (ADR-0007
/// §4) — and the waiters on them. A `send` adopts the task already running for its chunk
/// or creates exactly one, and then awaits it; the driver's timeout cancels that await
/// and never the task, whose lifetime is the daemon's (ADR-0007 §6). This commit gives
/// it `openSession` and `send` with `UploadTransport`'s signatures and not the
/// conformance: `confirmedProgress` and `finalize` arrive with it in the next commit,
/// and a placeholder that threw would make a stub speak a semantic error about a call
/// nothing has made. Nothing here resumes a waiter with an outcome yet — the completion
/// listener is that commit's too.
///
/// The control plane is reached through `PlaneExchange`, a request in and a response
/// out; the routes' bytes are `ControlPlaneWire`'s, pure. A task is registered only under
/// a description this transport can read as its own. One it cannot read is cancelled and
/// never registered, because a task that is not ours is not evidence about any upload —
/// "progress" it might seem to show is a string somebody else wrote.
public actor BackgroundSessionTransport {
    private let plane: any PlaneExchange
    private let tasks: any PartTaskSession
    private let chunkFiles: ChunkFiles

    /// The tasks this transport has named, by name. Keyed by the decoded description, so
    /// a key exists only for a task that decoded.
    private var inFlight: [TaskDescription: PartTaskID] = [:]

    /// The descriptions a `send` is creating a task for and has not registered yet. A
    /// send is inside `createTask` — or the plane call before it — for several awaits,
    /// and a second send for the chunk arriving in that window must wait, not create.
    private var creating: Set<TaskDescription> = []

    /// A ticket names one await. An actor counter, not entropy: it is compared to nothing
    /// outside this actor and need only be unique here.
    private typealias Ticket = Int
    private typealias Waiter = CheckedContinuation<TransferOutcome, any Error>
    private var nextTicket = 0

    /// The sends awaiting each task, by the description they await and their ticket.
    private var waiters: [TaskDescription: [Ticket: Waiter]] = [:]

    public init(plane: any PlaneExchange, tasks: any PartTaskSession, chunkFiles: ChunkFiles) {
        self.plane = plane
        self.tasks = tasks
        self.chunkFiles = chunkFiles
    }

    /// `POST /uploads` with the destination and the plan's chunk count; the identity Core
    /// receives is `<ref>/<uploadId>`, composed from the plane's answer.
    public func openSession(for intent: UploadIntent) async throws -> TransportSessionID {
        let answer = try await plane.perform(
            ControlPlaneWire.create(ref: intent.destination.rawValue, parts: intent.plan.chunkCount))
        let uploadId = try ControlPlaneWire.uploadId(from: answer)
        return SessionIdentity(ref: intent.destination.rawValue, uploadId: uploadId).composed
    }

    /// Adopt the task already in flight for `(session, chunk)` or create exactly one, then
    /// await it.
    ///
    /// Creating one: the chunk file, then a URL minted at this send — every send asks
    /// `/urls`, so the task's life and the URL's begin together and no cache and no clock
    /// are needed (ADR-0007 §6, F2) — then the task under the chunk's description. The
    /// description is marked as creating before the first await, so a second send that
    /// arrives inside the window waits on it. If any step throws, the mark is dropped,
    /// every waiter on that description is resumed with the same error — a waiter must
    /// always have a task or an error, and one on a creation that failed waits on
    /// nothing — and the error is rethrown: no event, and the next round tries again
    /// (ADR-0005 §8).
    ///
    /// Awaiting: a continuation the completion listener resumes. Cancelling the Swift
    /// task that awaits — which is what the driver's timeout does — resumes this await
    /// throwing `CancellationError`, removes its waiter, and does nothing to the daemon's
    /// task. The await and the task have different lifetimes; that is the sentence
    /// ADR-0005 §5 said the in-process double could not make.
    public func send(_ transfer: PlannedTransfer,
                     of intent: UploadIntent,
                     in session: TransportSessionID) async throws -> TransferOutcome {
        let identity = try SessionIdentity.parse(session)
        let description = TaskDescription(upload: intent.upload, session: session, chunk: transfer.chunk)

        if inFlight[description] == nil, !creating.contains(description) {
            creating.insert(description)
            do {
                let file = try chunkFiles.file(for: transfer, of: intent)
                let answer = try await plane.perform(
                    ControlPlaneWire.urls(ref: identity.ref, uploadId: identity.uploadId,
                                          parts: intent.plan.chunkCount))
                let signed = try ControlPlaneWire.partURLs(from: answer)
                // The plane numbers parts as Core numbers chunks: part n is `ChunkID(n)`.
                guard let url = signed.first(where: { $0.part == transfer.chunk.ordinal })?.url else {
                    throw ControlPlaneError.unreadableAnswer(status: answer.status)
                }
                let id = try await tasks.createTask(description: description.encoded, file: file, url: url)
                inFlight[description] = id
                creating.remove(description)
            } catch {
                creating.remove(description)
                resumeWaiters(on: description, throwing: error)
                throw error
            }
        }

        nextTicket += 1
        let ticket = nextTicket
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                store(continuation, for: description, ticket: ticket)
            }
        } onCancel: {
            Task { await self.abandon(description, ticket: ticket) }
        }
    }

    /// Adopt the tasks the daemon still holds. Explicit and once, before any send: the
    /// registry is what a `send` consults before creating a task, and a send that ran
    /// before adoption would create a second task for a chunk that already has one.
    ///
    /// A pending task whose description decodes is registered under it; one whose
    /// description does not is cancelled and never registered. Two pending tasks under
    /// one description keep the first — the lowest id — and the rest are cancelled. The
    /// list is sorted by id first, because the rule must not depend on the order the
    /// session lists them, which `URLSession` does not promise. A second call re-reads
    /// and re-registers, and cancels nothing it already holds — what it holds decoded
    /// once and decodes again, under the id it was registered with.
    public func adopt() async {
        let pending = await tasks.pendingTasks().sorted { $0.id.rawValue < $1.id.rawValue }
        for task in pending {
            guard let description = TaskDescription(decoding: task.description) else {
                await tasks.cancel(task.id)
                continue
            }
            if let held = inFlight[description], held != task.id {
                await tasks.cancel(task.id)
            } else {
                inFlight[description] = task.id
            }
        }
    }

    /// The chunks of `upload` with a registered task.
    public func inFlightChunks(of upload: UploadID) -> Set<ChunkID> {
        Set(inFlight.keys.filter { $0.upload == upload }.map(\.chunk))
    }

    /// How many sends are awaiting `chunk` of `upload`. A probe for the tests that wait
    /// for a concurrent send to reach its await; nothing in production reads it.
    func awaiting(_ chunk: ChunkID, of upload: UploadID) -> Int {
        waiters.filter { $0.key.upload == upload && $0.key.chunk == chunk }
            .reduce(0) { $0 + $1.value.count }
    }

    private func store(_ waiter: Waiter, for description: TaskDescription, ticket: Ticket) {
        waiters[description, default: [:]][ticket] = waiter
    }

    /// Cancel one await: remove its waiter and resume it throwing. The task it awaited is
    /// untouched. Finding no waiter is a no-op, and it is never "not stored yet": `store`
    /// runs on this actor inside the continuation body, before `send`'s first suspension
    /// after the handler is installed, and the hop `onCancel` spawns cannot run on the
    /// actor until that suspension. It is "already resumed" — a completion landed and the
    /// timeout a moment later — and a ticket already resumed needs nothing.
    private func abandon(_ description: TaskDescription, ticket: Ticket) {
        guard let waiter = waiters[description]?.removeValue(forKey: ticket) else { return }
        if waiters[description]?.isEmpty == true { waiters[description] = nil }
        waiter.resume(throwing: CancellationError())
    }

    /// A creation that failed leaves nothing to wait on: every send waiting on the
    /// description ends with the same error, which the driver treats as it treats any
    /// thrown error (ADR-0005 §8).
    private func resumeWaiters(on description: TaskDescription, throwing error: any Error) {
        guard let pending = waiters.removeValue(forKey: description) else { return }
        for waiter in pending.values { waiter.resume(throwing: error) }
    }
}
