import Foundation
import DunnageCore

/// The transport that leaves the process: part PUTs go over a background session, whose
/// tasks the daemon keeps across relaunch, and this actor is what the next process uses
/// to find them again.
///
/// It owns a registry of the tasks it has named — one per `(session, chunk)` (ADR-0007
/// §4) — and the waiters on them. A `send` adopts the task already running for its chunk
/// or creates exactly one, and then awaits it; the driver's timeout cancels that await
/// and never the task, whose lifetime is the daemon's (ADR-0007 §6). The completion
/// listener maps what the session reports to one `TransferOutcome` and hands it to the
/// sends awaiting that task, and a completion nobody was awaiting waits in memory for the
/// first send that asks. All four of `UploadTransport`'s calls are here, so the
/// conformance is declared at the foot of this file.
///
/// The control plane is reached through `PlaneExchange`, a request in and a response
/// out; the routes' bytes are `ControlPlaneWire`'s, pure. A task is registered only under
/// a description this transport can read as its own. One it cannot read is cancelled and
/// never registered, because a task that is not ours is not evidence about any upload —
/// "progress" it might seem to show is a string somebody else wrote.
///
/// **A task is registered before it is started, so a completion can never arrive for a
/// task this transport has not yet named.** `PartTaskSession` separates the two for that
/// reason, as `URLSession` does: create, then register, then start.
///
/// What a session reported is an answer a driver received, and it is never confirmed
/// progress: `confirmedProgress` asks `/parts` and reads nothing else, whatever any
/// completion said (ADR-0001 §3, ADR-0007 §5).
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

    /// The outcomes no send was awaiting when they arrived, by the description they name.
    ///
    /// A completion for a task the previous process created lands here after relaunch: it
    /// is handed to the first `send` that asks for that chunk and then forgotten, and it
    /// never reaches the log, because the log records answers a driver received and a
    /// driver that never asked was never answered (ADR-0007 §5).
    private var unclaimed: [TaskDescription: TransferOutcome] = [:]

    /// Whether the completion listener has been started. A code guard and not an
    /// invariant with a test: two iterators on one `AsyncStream` split its elements
    /// rather than duplicating them, so a second listener is not observable from outside
    /// this actor and no test could tell the difference.
    private var listening = false

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

    /// Answer from a completion already held for this chunk, or adopt the task already in
    /// flight for `(session, chunk)`, or create exactly one — and then await it.
    ///
    /// A held completion is one the session reported while no send was awaiting it. It is
    /// handed over here and forgotten, and nothing is created: the task it belonged to
    /// left the registry when it was delivered, so the send after this one creates anew.
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

        // The completion this chunk already has, if one arrived while nothing was
        // awaiting it. Taken before anything is created, and taken once.
        if let held = unclaimed.removeValue(forKey: description) { return held }

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
                // Registered before it is started, never after. A session says nothing
                // about a task it has not begun, so a task named here cannot be reported
                // on before this transport can say whose it is; started first, its
                // completion could name an id the registry does not hold yet, and
                // `deliver` would drop it as not ours.
                inFlight[description] = id
                creating.remove(description)
                await tasks.start(id)
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
    /// It also starts the completion listener, and starts it here rather than in `init`:
    /// an actor's initialiser cannot safely spawn work that awaits the actor it is still
    /// initialising, and adoption is already the one call that runs before any send.
    ///
    /// A pending task whose description decodes is registered under it; one whose
    /// description does not is cancelled and never registered. Two pending tasks under
    /// one description keep the first — the lowest id — and the rest are cancelled. The
    /// list is sorted by id first, because the rule must not depend on the order the
    /// session lists them, which `URLSession` does not promise. A second call re-reads
    /// and re-registers, and cancels nothing it already holds — what it holds decoded
    /// once and decodes again, under the id it was registered with.
    public func adopt() async {
        startListening()
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

    /// One completion, mapped to the one outcome that means it and handed to the sends
    /// awaiting it. ADR-0007 §5's table, and nothing else:
    ///
    ///     answered, 2xx           reportedComplete(chunk)
    ///     answered, any other     refused(chunk)      an answer, and the answer was no
    ///     noAnswer                interrupted(chunk)  no answer arrived
    ///
    /// The ETag is not read — the session never sees one, because the device retains no
    /// ETag (ADR-0006 §4) and `finalize` is a control-plane call for that reason.
    ///
    /// A completion whose id is registered under no description is dropped. A task
    /// cancelled at adoption still reports, and what it reports is not evidence about any
    /// upload. A completion nobody was awaiting is held for the first send that asks.
    ///
    /// Either way the task leaves the registry, because it has ended. That is the
    /// expired-URL path (ADR-0007 §6): a PUT presented with an expired URL is refused,
    /// the refusal reaches the driver, and the next send for that chunk creates a task
    /// with a URL minted at that send.
    func deliver(_ completion: TaskCompletion) {
        guard let description = inFlight.first(where: { $0.value == completion.id })?.key else {
            return
        }
        let outcome: TransferOutcome
        switch completion.completion {
        case .answered(let status) where 200...299 ~= status:
            outcome = .reportedComplete(description.chunk)
        case .answered:
            outcome = .refused(description.chunk)
        case .noAnswer:
            outcome = .interrupted(description.chunk)
        }

        inFlight[description] = nil
        guard let pending = waiters.removeValue(forKey: description), !pending.isEmpty else {
            unclaimed[description] = outcome
            return
        }
        for waiter in pending.values { waiter.resume(returning: outcome) }
    }

    /// Ask the authority what it durably holds: `GET /uploads/{ref}/parts`, and nothing
    /// else. A completion this transport saw is not an input here (ADR-0001 §3).
    ///
    /// The answer is set-shaped because the authority's is: it reports the part numbers it
    /// holds, not a resumable byte offset. `parts.ts` refuses a missing uploadId with 400,
    /// an unauthenticated caller with 401, and a `ListParts` page it had to truncate with
    /// 500 — reading past one page is 4b's, and a truncated list served as if it were whole
    /// would under-report what the authority holds.
    ///
    /// The chunk files of what it confirms are deleted here, and here only: a chunk file
    /// goes when the authority confirms the chunk and not when a completion reports it, so
    /// the files that exist at once are bounded by the in-flight set (ADR-0007 §7).
    ///
    /// 404 becomes `TransportError.unknownSession`, and that reading is provisional: it is
    /// the stand-in's, until 4b's contract run shows what the plane renders for an upload
    /// S3 has no record of (ADR-0007 §9, item 2).
    public func confirmedProgress(for upload: UploadID,
                                  in session: TransportSessionID) async throws -> Confirmation {
        let identity = try SessionIdentity.parse(session)
        let answer = try await plane.perform(
            ControlPlaneWire.parts(ref: identity.ref, uploadId: identity.uploadId))
        let held: Set<Int>
        do {
            held = try ControlPlaneWire.heldParts(from: answer)
        } catch ControlPlaneError.noSuchUpload {
            throw TransportError.unknownSession
        }
        let confirmed = Set(held.map(ChunkID.init))
        try chunkFiles.discard(confirmed, of: upload)
        return Confirmation(upload: upload, session: session, progress: .chunks(confirmed))
    }

    /// Ask the plane to create the object from what the authority holds: `POST
    /// /uploads/{ref}/complete`. The etag it answers with is not read.
    ///
    /// One refusal is named. `TransportError.incompleteUpload` is a complete over parts the
    /// authority does not hold — the stand-in's 400 (spec §3.2) — and not a malformed
    /// request, which stays the route's own refusal. The plane today cannot make that
    /// refusal: `complete.ts` does not know the plan's N and completes over whatever
    /// `ListParts` returns. Core finalizes only once every chunk is confirmed, so the case
    /// this names is the authority having lost a part between the ask and the complete.
    public func finalize(_ session: TransportSessionID) async throws {
        let identity = try SessionIdentity.parse(session)
        let answer = try await plane.perform(
            ControlPlaneWire.complete(ref: identity.ref, uploadId: identity.uploadId))
        do {
            try ControlPlaneWire.completed(from: answer)
        } catch ControlPlaneError.incompleteUpload {
            throw TransportError.incompleteUpload
        }
    }

    /// How many completions are held for `chunk` of `upload` with no send to hand them to.
    /// A probe for the tests, like `awaiting(_:of:)`; nothing in production reads it.
    func unclaimedCount(_ chunk: ChunkID, of upload: UploadID) -> Int {
        unclaimed.keys.filter { $0.upload == upload && $0.chunk == chunk }.count
    }

    /// The completion listener: one `Task` reading the session's stream and delivering
    /// each completion to this actor.
    ///
    /// It runs for the process's lifetime and is never cancelled, so nothing depends on
    /// its ending. That is what lets a completion for a task the previous process created
    /// arrive after relaunch and still be handed to a send.
    private func startListening() {
        guard !listening else { return }
        listening = true
        // Isolated to this actor, so each completion is delivered on it; the actor is
        // free while the loop is suspended waiting for the next one.
        Task {
            for await completion in tasks.completions {
                deliver(completion)
            }
        }
    }

    /// How many sends are awaiting `chunk` of `upload`. A probe for the tests that wait
    /// for a concurrent send to reach its await; nothing in production reads it.
    func awaiting(_ chunk: ChunkID, of upload: UploadID) -> Int {
        waiters.filter { $0.key.upload == upload && $0.key.chunk == chunk }
            .reduce(0) { $0 + $1.value.count }
    }

    private func store(_ waiter: Waiter, for description: TaskDescription, ticket: Ticket) {
        waiters[description, default: [:]][ticket] = waiter
        #if DEBUG
        noteRegistration(description)
        #endif
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

#if DEBUG
    /// How many waiters `store` has put on each description since this transport was made,
    /// and the observations waiting for a count to be reached.
    ///
    /// **Test-only state, and the only state here that is held rather than read.**
    /// `awaiting(_:of:)` and `unclaimedCount(_:of:)` beside it are probes over dictionaries
    /// this transport keeps anyway and cost nothing; this one keeps an `Int` per
    /// `TaskDescription` that nothing decrements, on an actor that lives as long as the
    /// process. There is no per-upload site to drop it at — `finalize` clears nothing here,
    /// `confirmedProgress` discards chunk files through `ChunkFiles`, and `deliver`'s
    /// removal is per description, where a reset would zero a count the tests read as
    /// cumulative — and inventing one for a counter no shipped code reads is the
    /// speculative abstraction this repository refuses. So it never exists in a shipped
    /// build: everything under this `#if DEBUG`, including the one call `store` makes, is
    /// compiled out of a Release configuration.
    ///
    /// **Cumulative and not current.** A threshold on the live count cannot tell "one
    /// waiter arrived" from "a first waiter has gone and a second arrived", which is
    /// exactly `TransportDriverTests`'s case: the driver's timeout removes the first send's
    /// waiter before the send that follows the interruption stores its own.
    private var registrations: [TaskDescription: Int] = [:]
    private var registrationObservers: [RegistrationObserver] = []

    private struct RegistrationObserver {
        let upload: UploadID
        let chunk: ChunkID
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    /// Return once `count` sends have registered a waiter on `chunk` of `upload`, counting
    /// every waiter stored since this transport was made — at once if that many already
    /// have.
    ///
    /// It resumes from inside `store(_:for:ticket:)`, where the waiter comes to exist, so
    /// when this returns the registration it counted is one `awaiting(_:of:)` can see. The
    /// count sums every description matching `(upload, chunk)`, as `awaiting(_:of:)`
    /// filters, so nothing here resolves an upload to a session.
    func whenRegistered(_ count: Int, on chunk: ChunkID, of upload: UploadID) async {
        if registered(chunk, of: upload) >= count { return }
        await withCheckedContinuation { continuation in
            registrationObservers.append(
                RegistrationObserver(upload: upload, chunk: chunk, count: count,
                                     continuation: continuation))
        }
    }

    private func registered(_ chunk: ChunkID, of upload: UploadID) -> Int {
        registrations.filter { $0.key.upload == upload && $0.key.chunk == chunk }
            .reduce(0) { $0 + $1.value }
    }

    /// One more waiter on this description, and every observation the new count satisfies.
    private func noteRegistration(_ description: TaskDescription) {
        registrations[description, default: 0] += 1
        var stillWaiting: [RegistrationObserver] = []
        for observer in registrationObservers {
            if observer.upload == description.upload, observer.chunk == description.chunk,
               registered(observer.chunk, of: observer.upload) >= observer.count {
                observer.continuation.resume()
            } else {
                stillWaiting.append(observer)
            }
        }
        registrationObservers = stillWaiting
    }
#endif
}

extension BackgroundSessionTransport: UploadTransport {}
