import Foundation
import DunnageCore
import DunnageDriver
import DunnageLedger
import DunnageTransport

/// What one chunk's row shows. The four words spec §4.2 names, and no fifth.
enum ChunkStatus: String, Sendable {
    case planned
    case inFlight = "in flight"
    case reported
    case confirmed
}

/// The launch arguments the tests use (spec §4.4). Read from the process's own arguments
/// rather than from `UserDefaults`, so nothing this app is told on the command line
/// survives into a defaults database the next launch would read back.
struct LaunchArguments: Sendable {
    var standInBaseURL: URL?
    var token: String?
    var quietAfter: Duration?

    #if DEBUG
    /// Which transport the driver is handed, read from `-transport`. `forgetful` installs
    /// the negative control (spec §7 rider b); anything else, and the absence of the
    /// argument, leaves the honest transport in place. A release build has no such
    /// argument, because it has no control to name.
    var transport: String?

    /// Whether this process was given any launch arguments at all.
    ///
    /// A process the system relaunched to deliver its background session's events is given
    /// none — observed on the simulator, where the whole argument vector is the executable
    /// path. That is what lets `-transport`'s *absence* in a launch that was given
    /// arguments mean "no control", and its absence in a launch given none mean "whatever
    /// the last launch that could say anything said".
    var wasGivenArguments = false
    #endif

    static func parse(_ arguments: [String]) -> LaunchArguments {
        func value(of name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        var parsed = LaunchArguments(
            standInBaseURL: value(of: "-standin-base-url").flatMap(URL.init(string:)),
            token: value(of: "-token"),
            quietAfter: value(of: "-quiet-after").flatMap(Double.init).map { .seconds($0) })
        #if DEBUG
        parsed.transport = value(of: "-transport")
        parsed.wasGivenArguments = arguments.count > 1
        #endif
        return parsed
    }
}

/// The screen's state, and the one place the app drives an upload.
///
/// **§4.3's precondition, which is what makes the screen's answer evidence about the log:**
/// what this publishes is derived by replaying the ledger, plus the transport's in-flight
/// set for `in flight`. There is no upload state of its own here — no cached phase, no
/// remembered confirmation, no counter — so "chunk 3 shows confirmed after relaunch" is a
/// statement about the file the previous process left and not about anything this process
/// was told. A later view model that cached state would break the evidence and not merely
/// the architecture.
///
/// The re-derivation is driven by the log itself: `ObservedEventLog` calls back after every
/// append, and that call back is the only thing that refreshes the screen. No timer and no
/// poll — a screen on a timer would be a wall clock inside the thing the tier-2 test reads.
@MainActor
final class UploadModel: ObservableObject {

    /// One chunk per 64 KiB. A number the app chooses, not Core's: Core is handed a plan.
    nonisolated static let chunkSize = 64 * 1024

    /// The background session's identifier (spec §4.1). One per process, and the app owns
    /// it because only an app can own a background session.
    nonisolated static let backgroundSessionIdentifier = "com.example.dunnage.background"

    @Published var token: String
    @Published var baseURLText: String
    @Published private(set) var statuses: [ChunkID: ChunkStatus] = [:]
    @Published private(set) var chunks: [ChunkID] = []
    @Published private(set) var phase: String = "no upload"
    @Published private(set) var note: String = ""
    @Published private(set) var lastExit: String

    private let container: Container
    private let log: FileEventLog
    private let tasks: URLSessionPartTasks
    private let arguments: LaunchArguments

    /// Built once, on the first `begin()`, from the base URL and token in force then. Once
    /// only, because a second transport over the same `PartTaskSession` would take a share
    /// of one completion stream: two iterators on an `AsyncStream` split its elements, and
    /// half the completions would reach a transport nothing was awaiting on.
    private var transport: BackgroundSessionTransport?
    private var driver: UploadDriver?

    /// The upload the screen is showing. One at a time: the driver is single-upload
    /// (ADR-0005), so the app resumes the ledger's uploads in turn (ADR-0007 "What this
    /// costs").
    private var showing: UploadID?

    /// Where the two fields are kept between launches.
    ///
    /// **Configuration, and never upload state.** An endpoint and a credential are what the
    /// operator typed, the way any app remembers what a text field held; what an upload has
    /// done is still derived from the log alone and from nothing here (§4.3). Keys of their
    /// own, because iOS puts a `-name value` launch argument into the volatile defaults
    /// domain under `name`, and a value written to that name would be shadowed by it.
    ///
    /// It is not a convenience. The system relaunches this app to deliver its background
    /// session's events, and a relaunch the system performs carries no launch arguments —
    /// observed on the simulator, where `nsurlsessiond` brought the app back 170 ms before
    /// the test asked it to. A process that only ever learned its endpoint from a launch
    /// argument comes up unable to ask the authority anything.
    private static let baseURLKey = "dunnage.configured-base-url"
    private static let tokenKey = "dunnage.configured-token"

    #if DEBUG
    /// Which transport the driver is handed, remembered for exactly the reason above.
    ///
    /// The relaunch that matters here is the system's, and it carries no launch arguments,
    /// so a control installed by `-transport` would be gone from the one process the tier-2
    /// run reads. It is remembered under a key of its own, like the endpoint and the token,
    /// and it is configuration of a debug build and never upload state: what the control
    /// forgets across a relaunch is its own memory of what it reported, and that forgetting
    /// is the fault being demonstrated.
    ///
    /// A launch that was given arguments records what `-transport` said, including that it
    /// said nothing — so a run that names no control clears one an earlier run installed,
    /// and the tier-2 test of claim 4 is never handed the control by a run that went before
    /// it. A launch given no arguments reads what was recorded.
    private static let transportKey = "dunnage.configured-transport"
    private let installedTransport: String?
    #endif

    init(container: Container, tasks: URLSessionPartTasks, arguments: LaunchArguments) {
        let remembered = UserDefaults.standard
        self.container = container
        self.tasks = tasks
        self.arguments = arguments
        self.log = FileEventLog(directory: container.ledgerDirectory)
        self.token = arguments.token ?? remembered.string(forKey: Self.tokenKey) ?? ""
        self.baseURLText = arguments.standInBaseURL?.absoluteString
            ?? remembered.string(forKey: Self.baseURLKey) ?? ""
        self.lastExit = container.takeLastExit() ?? "none"
        #if DEBUG
        if arguments.wasGivenArguments {
            remembered.set(arguments.transport, forKey: Self.transportKey)
            self.installedTransport = arguments.transport
        } else {
            self.installedTransport = remembered.string(forKey: Self.transportKey)
        }
        #endif
    }

    /// Adopt whatever the daemon still holds, then pick up every upload the ledger knows
    /// about, in turn.
    ///
    /// `adopt()` first and always: the registry is what a `send` consults before creating a
    /// task, and a send that ran before adoption would create a second task for a chunk
    /// that already has one (ADR-0007 §4).
    func begin() async {
        guard let driver = makeDriverIfPossible() else { return }
        await transport?.adopt()
        let uploads: [UploadID]
        do {
            uploads = try await log.uploads()
        } catch {
            note = "ledger: \(error)"
            return
        }
        showing = uploads.last
        await refresh()
        // In turn, and each one's failure is its own. A thrown error is no event (ADR-0005
        // §8) and it says nothing about the next upload on the ledger; one upload the
        // authority has forgotten must not stop the app picking up the rest.
        for upload in uploads {
            showing = upload
            do {
                try await driver.resume(upload)
            } catch {
                note = "resume \(upload.rawValue): \(error)"
            }
            await refresh()
        }
    }

    /// Declare an upload for `source` and drive it as far as it goes.
    ///
    /// The upload id is a UUID and the destination is the same UUID's string, which the
    /// ref grammar admits (`cloud/handlers/identity.ts`). Randomness lives here, in the
    /// app, and never in Core (spec §4.1).
    func startUpload(from source: URL) async {
        guard let driver = makeDriverIfPossible() else { return }
        do {
            let identifier = UUID().uuidString
            let upload = UploadID(identifier)
            let payload = try container.adoptPayload(from: source, for: upload)
            let bytes = try Data(contentsOf: container.resolve(payload)).count
            let intent = UploadIntent(upload: upload,
                                      destination: DestinationRef(identifier),
                                      payload: payload,
                                      plan: ChunkPlan(totalBytes: bytes,
                                                      chunkSize: Self.chunkSize))
            showing = upload
            await refresh()
            try await driver.run(intent)
        } catch {
            note = "upload: \(error)"
        }
        await refresh()
    }

    /// The one place the transport and the driver are constructed, and it happens once.
    private func makeDriverIfPossible() -> UploadDriver? {
        if let driver { return driver }
        guard let baseURL = URL(string: baseURLText), !baseURLText.isEmpty else {
            note = "no base URL"
            return nil
        }
        UserDefaults.standard.set(baseURLText, forKey: Self.baseURLKey)
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        let plane = URLSessionControlPlane(
            baseURL: baseURL,
            bearerToken: token,
            session: URLSession(configuration: .ephemeral))
        let files = ChunkFiles(directory: container.partsDirectory,
                               resolve: { [container] ref in container.resolve(ref) })
        let transport = BackgroundSessionTransport(plane: plane, tasks: tasks, chunkFiles: files)
        let observed = ObservedEventLog(wrapped: log) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        // The driver is handed whichever transport the arguments name, and the model keeps
        // its `BackgroundSessionTransport` either way: `adopt()` and `inFlightChunks(of:)`
        // are the real transport's, so the screen and the registry are untouched. Which
        // transport that is, and the type that answers when it is not the honest one, is
        // decided in `App/Dunnage/NegativeControl/` — a `#if DEBUG` directory, so nothing
        // here names a control a release build does not have.
        #if DEBUG
        let driven = transportForTheDriver(named: installedTransport, wrapping: transport)
        #else
        let driven: any UploadTransport = transport
        #endif
        let driver = UploadDriver(transport: driven,
                                  log: observed,
                                  clock: SystemClock(),
                                  quietAfter: arguments.quietAfter ?? .seconds(600))
        self.transport = transport
        self.driver = driver
        return driver
    }

    /// Re-derive everything on the screen from the log, plus the transport's in-flight set.
    /// Nothing is remembered between calls.
    func refresh() async {
        guard let upload = showing else { return }
        let records: [EventRecord]
        do {
            records = try await log.records(for: upload)
        } catch {
            note = "replay: \(error)"
            return
        }
        let events = records.map(\.event)
        let state = UploadTransition.replay(events)
        phase = Self.name(of: state)

        guard let intent = Self.intent(in: state) else {
            chunks = []
            statuses = [:]
            return
        }
        let inFlight = await transport?.inFlightChunks(of: upload) ?? []
        chunks = intent.plan.chunks
        statuses = Self.statuses(of: intent, given: state, events: events, inFlight: inFlight)
    }

    // MARK: derived from the log, and from nothing else

    private static func name(of state: UploadMachineState) -> String {
        switch state {
        case .undeclared:   "no upload"
        case .declared:     "declared"
        case .transferring: "transferring"
        case .finalizing:   "finalizing"
        case .completed:    "completed"
        case .failed:       "failed"
        }
    }

    private static func intent(in state: UploadMachineState) -> UploadIntent? {
        switch state {
        case .undeclared:                          nil
        case .declared(let intent):                intent
        case .transferring(let intent, _, _, _):   intent
        case .finalizing(let intent, _, _, _):     intent
        case .completed(let intent):               intent
        case .failed(let intent, _, _):            intent
        }
    }

    /// Confirmed beats reported beats in flight beats planned.
    ///
    /// `reported` is what a completion said since the authority last spoke, so it is read
    /// off the events and reset by `authorityReported` — a report is an observation about a
    /// request and never progress, and the screen keeps the two words apart for the reason
    /// ADR-0001 §3 keeps the two claims apart.
    private static func statuses(of intent: UploadIntent,
                                 given state: UploadMachineState,
                                 events: [UploadEvent],
                                 inFlight: Set<ChunkID>) -> [ChunkID: ChunkStatus] {
        var reported: Set<ChunkID> = []
        for event in events {
            switch event {
            case .chunkTransferReported(let chunk): reported.insert(chunk)
            case .authorityReported:                reported = []
            default:                                break
            }
        }
        let confirmed = Self.confirmed(in: state)?.confirmedChunks(in: intent.plan) ?? []
        var statuses: [ChunkID: ChunkStatus] = [:]
        for chunk in intent.plan.chunks {
            if confirmed.contains(chunk) {
                statuses[chunk] = .confirmed
            } else if reported.contains(chunk) {
                statuses[chunk] = .reported
            } else if inFlight.contains(chunk) {
                statuses[chunk] = .inFlight
            } else {
                statuses[chunk] = .planned
            }
        }
        return statuses
    }

    private static func confirmed(in state: UploadMachineState) -> ConfirmedProgress? {
        switch state {
        case .transferring(_, _, let confirmed, _):  confirmed
        case .finalizing(_, _, let confirmed, _):    confirmed
        case .failed(_, _, let confirmed):           confirmed
        // A completed upload's confirmation is not on the state, and the screen does not
        // invent one: every chunk of a completed upload is confirmed by the phase itself.
        case .completed(let intent):                 .chunks(Set(intent.plan.chunks))
        case .undeclared, .declared:                 nil
        }
    }
}

/// `UploadEventLog` with a callback after every append.
///
/// The screen re-derives when the log changes, and the log is the only thing that says it
/// changed. A decorator and not a field on the driver: ADR-0003 §2 keeps the driver without
/// state, and a driver that told a view about its progress would be a second answer to a
/// question the log already answers.
struct ObservedEventLog: UploadEventLog {
    let wrapped: FileEventLog
    let changed: @Sendable () -> Void

    @discardableResult
    func append(_ events: [UploadEvent], for upload: UploadID) async throws -> [EventRecord] {
        let records = try await wrapped.append(events, for: upload)
        changed()
        return records
    }

    func records(for upload: UploadID) async throws -> [EventRecord] {
        try await wrapped.records(for: upload)
    }

    func uploads() async throws -> [UploadID] {
        try await wrapped.uploads()
    }
}
