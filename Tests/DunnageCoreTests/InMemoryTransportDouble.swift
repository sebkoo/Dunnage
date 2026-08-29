import DunnageCore

/// An in-memory `UploadTransport`.
///
/// It implements the *transport contract*, not any vendor's product. It models both shapes
/// a real authority takes — a set of held unit ids with gaps in it, and a single contiguous
/// byte offset — because those are the two contracts Core has to survive, and choosing one
/// would quietly bake that choice into every test built on it.
actor InMemoryTransportDouble: UploadTransport {

    /// What the authority is able to state about itself.
    enum AuthorityShape: Sendable {
        /// Enumerates the units it holds. Gaps are expressible, and mean what they say.
        case setShaped
        /// Reports one contiguous prefix. It may hold more than it can report.
        case offsetShaped
    }

    /// What the double does with the next send for a chunk.
    enum Behavior: Sendable, Equatable {
        case succeed
        case fail(FailureReason)
        /// Produces no outcome, and nothing lands.
        case stall
        /// Lands, and delivers its completion report twice.
        case duplicate
    }

    private struct Session {
        let intent: UploadIntent
        var units: Set<ChunkID> = []
        var spans: [ByteRange] = []
        var finalized = false
    }

    let shape: AuthorityShape

    private var sessions: [TransportSessionID: Session] = [:]
    private var nextSession = 1
    private var behaviors: [ChunkID: Behavior] = [:]
    private var defaultBehavior: Behavior = .succeed

    /// Completion reports the transport has delivered, in order, duplicates included.
    private(set) var deliveredReports: [ChunkID] = []

    init(shape: AuthorityShape) {
        self.shape = shape
    }

    // MARK: scripting

    func script(_ behavior: Behavior, for chunk: ChunkID) { behaviors[chunk] = behavior }
    func scriptEverything(_ behavior: Behavior) { defaultBehavior = behavior; behaviors = [:] }

    /// The authority loses all record of the operation, as an aborted multipart upload does.
    func forget(_ session: TransportSessionID) { sessions[session] = nil }

    func isFinalized(_ session: TransportSessionID) -> Bool {
        sessions[session]?.finalized ?? false
    }

    // MARK: UploadTransport

    func openSession(for intent: UploadIntent) async throws -> TransportSessionID {
        let session = TransportSessionID("session-\(nextSession)")
        nextSession += 1
        sessions[session] = Session(intent: intent)
        return session
    }

    func send(_ transfer: PlannedTransfer,
              in session: TransportSessionID) async throws -> TransferOutcome {
        guard var state = sessions[session] else { throw TransportError.unknownSession }

        switch behaviors[transfer.chunk] ?? defaultBehavior {
        case .stall:
            // No outcome, and nothing lands. The caller learns nothing either way.
            return .stalled

        case .fail(let reason):
            return .failed(reason)

        case .succeed, .duplicate:
            state.units.insert(transfer.chunk)
            state.spans.append(transfer.range)
            sessions[session] = state

            let duplicated = (behaviors[transfer.chunk] ?? defaultBehavior) == .duplicate
            deliveredReports.append(transfer.chunk)
            if duplicated { deliveredReports.append(transfer.chunk) }
            return .reportedComplete(transfer.chunk)
        }
    }

    func confirmedProgress(in session: TransportSessionID) async throws -> Confirmation {
        guard let state = sessions[session] else { throw TransportError.unknownSession }

        let progress: ConfirmedProgress
        switch shape {
        case .setShaped:
            progress = .chunks(state.units)
        case .offsetShaped:
            // It may hold more than this. A prefix is all it can state.
            progress = .offset(ByteOffset(Self.contiguousPrefix(of: state.spans)))
        }
        return Confirmation(upload: state.intent.upload, session: session, progress: progress)
    }

    func finalize(_ session: TransportSessionID) async throws {
        guard var state = sessions[session] else { throw TransportError.unknownSession }
        guard state.units == Set(state.intent.plan.chunks) else {
            throw TransportError.incompleteUpload
        }
        state.finalized = true
        sessions[session] = state
    }

    /// How far a contiguous run from zero reaches. Spans above a gap are held but
    /// unreportable under an offset-shaped contract.
    private static func contiguousPrefix(of spans: [ByteRange]) -> Int {
        var end = 0
        for span in spans.sorted(by: { $0.start < $1.start }) {
            guard span.start.value <= end else { break }
            end = max(end, span.endExclusive.value)
        }
        return end
    }
}
