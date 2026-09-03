import Foundation

/// The daemon, behind `PartTaskSession`: a background `URLSession` that creates, starts,
/// cancels and reports on the part PUTs, and interprets none of them.
///
/// It is the production half of the boundary `BackgroundSessionTransport` is written
/// against. Nothing here reads a route, a field or a header: the outcome mapping is the
/// transport's (ADR-0007 §5) and the four routes' bytes are `ControlPlaneWire`'s. What
/// this file owns is the session's shape — the configuration ADR-0007 §6 fixes, the
/// create/start split ADR-0007 §4 requires, and the delegate's three-row table.
///
/// **What is established where.** Every line of this type needs a session, so none of it
/// is tier 1 and this file's commit adds no test.
///
/// - tier 1 (`swift test`): nothing here.
/// - simulator evidence (ADR-0007 §2, tier 2): that a created task is not begun until
///   `start`, observed as the kill landing mid-transfer with the part held; that a task
///   outlives the process and its completion arrives after relaunch; that a task adopted
///   after relaunch, with no map entry, is found through the session's own task list; and
///   that `urlSessionDidFinishEvents` reaches the handler the app installed.
/// - device harness (ADR-0007 §2, tier 3): whether the daemon keeps or cancels a killed
///   app's tasks (O-14); whether `timeoutIntervalForResource` counts while the app is
///   suspended (O-13); whether the daemon can read the copy the app made (O-15).
///
/// **One lock, and not an actor.** The handler and the id map are touched from two
/// places: the caller's, through `PartTaskSession`, and `URLSession`'s, through the
/// delegate. The delegate methods are not `async` and `URLSession` calls them on a queue
/// of its choosing, so an actor could not hold that state without hopping out of a
/// synchronous callback. One `NSLock` guards both, and the type is `@unchecked Sendable`
/// because that lock is the checking.
public final class URLSessionPartTasks: NSObject, PartTaskSession, URLSessionTaskDelegate,
                                        @unchecked Sendable {

    /// A part's URL is good for 900 seconds from its minting
    /// (`cloud/handlers/urls.ts`, `EXPIRES_IN_SECONDS`), and a task starts with whatever
    /// of that is left. A transfer that is never presented inside the life of its URL can
    /// only end in a refusal, so the daemon is given no longer than that life. 900 is a
    /// ceiling over the URL's life, not an exact match.
    ///
    /// The two 900s are one number in two languages and nothing a compiler sees connects
    /// them; ADR-0007 §6 is the rule, and the comment above `EXPIRES_IN_SECONDS` names
    /// this constant back. Lowering the plane's expiry without lowering this number turns
    /// the ceiling into a number that bounds nothing.
    public static let partTransferLifetime: Duration = .seconds(900)

    /// The configuration ADR-0007 §6 names, and only what it names. Each value has a
    /// reason; a value with no reason is a guess, so nothing else is set here.
    ///
    /// - `timeoutIntervalForResource` is `partTransferLifetime`, above.
    /// - `isDiscretionary` is false: the app asked for this transfer, and a discretionary
    ///   transfer is one the system may defer past the life of the URL it carries.
    /// - `sessionSendsLaunchEvents` is true: without it the system does not relaunch the
    ///   app to deliver the events, and the relaunch is what this phase is about.
    public static func backgroundConfiguration(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.timeoutIntervalForResource =
            TimeInterval(partTransferLifetime.components.seconds)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        return configuration
    }

    /// Guards `handler` and `tasks`, both of which the caller and the delegate touch.
    private let lock = NSLock()

    /// The app's relaunch handler, held until the events are finished and then dropped.
    private var handler: (@Sendable () -> Void)?

    /// The tasks this process created, by the id the caller was given. Tasks adopted
    /// after a relaunch have no entry here and are found through the session's own list.
    private var tasks: [PartTaskID: URLSessionTask] = [:]

    /// One stream for the process's lifetime, never finished: a completion for a task the
    /// previous process created arrives on it after relaunch, and the transport's
    /// listener runs as long as the process does (ADR-0007 §5).
    public let completions: AsyncStream<TaskCompletion>
    private let continuation: AsyncStream<TaskCompletion>.Continuation

    /// Assigned after `super.init()` because the session is built with this object as its
    /// delegate, and `self` is not available before then. Written once and never again.
    private var session: URLSession!

    public init(configuration: URLSessionConfiguration) {
        (completions, continuation) = AsyncStream<TaskCompletion>.makeStream()
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The handler the app is given by
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. This type
    /// stores it and never calls it itself; `urlSessionDidFinishEvents` is the one caller.
    public func finishedEvents(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    // MARK: PartTaskSession

    /// What the daemon still holds — this process's tasks and a previous process's alike,
    /// as the session itself lists them. A task with no description becomes the empty
    /// string, which `TaskDescription(decoding:)` refuses and the transport cancels: an
    /// unreadable name is not this transport's task, which is the existing rule and not a
    /// new one.
    public func pendingTasks() async -> [PendingTask] {
        await session.allTasks.map { task in
            PendingTask(id: PartTaskID(task.taskIdentifier),
                        description: task.taskDescription ?? "")
        }
    }

    /// Create the PUT for one part, and do not begin it.
    ///
    /// ADR-0007 §4 is the rule: a task is registered by its caller before it is started,
    /// so a completion can never name an id the registry does not hold yet. Begun here,
    /// this task could be reported on before `createTask` had even returned its id, and
    /// the completion would be dropped as not the transport's.
    public func createTask(description: String, file: URL, url: URL) async throws -> PartTaskID {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        let id = PartTaskID(task.taskIdentifier)
        lock.withLock { tasks[id] = task }
        return id
    }

    /// Begin a task. The one place in this file where a task is started, which is what
    /// ADR-0007 §4 asks of the split.
    ///
    /// Naming an id the session no longer holds is a no-op: the daemon finished the task
    /// or forgot it, and neither is evidence about an upload, so nothing is invented here.
    public func start(_ id: PartTaskID) async {
        await find(id)?.resume()
    }

    /// Cancel a task. Naming an id the session no longer holds is a no-op, for the reason
    /// `start` gives.
    public func cancel(_ id: PartTaskID) async {
        await find(id)?.cancel()
        lock.withLock { tasks[id] = nil }
    }

    /// Two sources, in order: the map, for tasks this process created; then the session's
    /// own task list, for tasks adopted after a relaunch, which have no map entry. Missing
    /// from both is the miss `start` and `cancel` treat as a no-op.
    private func find(_ id: PartTaskID) async -> URLSessionTask? {
        if let known = lock.withLock({ tasks[id] }) { return known }
        return await session.allTasks.first { $0.taskIdentifier == id.rawValue }
    }

    // MARK: URLSessionTaskDelegate

    /// One task ended, reported as a `PartTaskCompletion` and nothing else. ADR-0007 §5
    /// fixes this table at three rows, and the transport is what turns a row into a
    /// `TransferOutcome`:
    ///
    ///     an error                             noAnswer
    ///     no error, an HTTPURLResponse         answered(status:)
    ///     no error, no HTTPURLResponse         noAnswer
    ///
    /// The third row is the one worth stating. No status is invented for it: `answered`
    /// means a status was received, and fabricating one so the transport could call the
    /// part `refused` would state "the answer was no" where no answer arrived — the
    /// collapse the thesis forbids, in the one table this file touches.
    ///
    /// No header is read, including the one the data plane emits over a part PUT: the
    /// device retains none (ADR-0006 §4), and what the authority holds comes from
    /// `/parts` alone.
    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: (any Error)?) {
        let id = PartTaskID(task.taskIdentifier)
        lock.withLock { tasks[id] = nil }

        let completion: PartTaskCompletion
        if error != nil {
            completion = .noAnswer
        } else if let answer = task.response as? HTTPURLResponse {
            completion = .answered(status: answer.statusCode)
        } else {
            completion = .noAnswer
        }
        continuation.yield(TaskCompletion(id: id, completion: completion))
    }

    /// Every event for this session has been delivered, so the app may tell the system it
    /// is done being awake. The handler is the app's, installed through `finishedEvents`,
    /// called on the main actor as UIKit requires and then dropped: it is good for one
    /// relaunch, and the next one brings another.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock {
            defer { self.handler = nil }
            return self.handler
        }
        guard let handler else { return }
        Task { @MainActor in handler() }
    }
}
