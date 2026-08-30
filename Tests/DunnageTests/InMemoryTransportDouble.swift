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

    /// Whether completed work survives a network interruption.
    enum Durability: Sendable, Equatable {
        /// Completed units outlive an interruption. A set-shaped authority holding parts,
        /// and a server speaking a resumable upload protocol, both behave this way.
        case retainsCompletedUnits
        /// Nothing outlives an interruption. A single whole-object request behaves this
        /// way: there is no unit smaller than the object, so an interrupted transfer
        /// leaves the authority holding nothing it can confirm.
        case retainsNothing
    }

    /// What the double does with the next send for a chunk.
    enum Behavior: Sendable, Equatable {
        case succeed
        /// The transport answers, and the answer is no. Nothing lands.
        case refuse
        /// No answer, and nothing lands.
        case stall
        /// No answer, and the unit lands anyway.
        ///
        /// Indistinguishable from `.stall` at the call site, and that is the whole point:
        /// when the answer never arrives, the outcome cannot carry a claim about whether
        /// the bytes reached the authority. Only the authority separates these two.
        case landWithoutAnswering
        /// Lands, and delivers its completion report twice.
        case duplicate
    }

    private struct Session {
        let intent: UploadIntent
        var units: Set<ChunkID> = []
        var spans: [ByteRange] = []
        var finalized = false
    }

    /// Every call the transport was asked to perform, in order.
    ///
    /// What a driver did, as the transport saw it. Recorded on entry, so a call that throws
    /// or never answers is still a call that was made.
    enum Call: Hashable, Sendable {
        case opened
        case sent(ChunkID)
        case asked(TransportSessionID)
        case finalized(TransportSessionID)
    }

    let shape: AuthorityShape
    let durability: Durability

    private var sessions: [TransportSessionID: Session] = [:]
    private var nextSession = 1
    private var behaviors: [ChunkID: Behavior] = [:]
    private var defaultBehavior: Behavior = .succeed

    /// Behaviours queued for a chunk's next sends, ahead of whatever it is scripted to do
    /// standingly. A transport that answers differently on the second try is the ordinary
    /// case, not an exotic one, and a driver that retries cannot be exercised without it.
    private var queued: [ChunkID: [Behavior]] = [:]

    private(set) var calls: [Call] = []

    /// Completion reports the transport has delivered, in order, duplicates included.
    private(set) var deliveredReports: [ChunkID] = []

    init(shape: AuthorityShape, durability: Durability = .retainsCompletedUnits) {
        self.shape = shape
        self.durability = durability
    }

    // MARK: scripting

    func script(_ behavior: Behavior, for chunk: ChunkID) { behaviors[chunk] = behavior }
    func scriptEverything(_ behavior: Behavior) { defaultBehavior = behavior; behaviors = [:] }

    /// Answer this way once, on the next send of `chunk`, and then as before. Repeated
    /// calls queue up in the order they were made.
    func scriptOnce(_ behavior: Behavior, for chunk: ChunkID) {
        queued[chunk, default: []].append(behavior)
    }

    /// A network interruption: the connection dropped mid-transfer.
    ///
    /// This models a dropped connection and nothing else. It is not process death, and no
    /// test may be named or read as though it were.
    func interrupt(_ session: TransportSessionID) {
        guard durability == .retainsNothing, var state = sessions[session] else { return }
        // No unit smaller than the object, so there is nothing partial left to hold.
        state.units = []
        state.spans = []
        sessions[session] = state
    }

    /// The authority loses all record of the operation, as an aborted multipart upload does.
    func forget(_ session: TransportSessionID) { sessions[session] = nil }

    func isFinalized(_ session: TransportSessionID) -> Bool {
        sessions[session]?.finalized ?? false
    }

    // MARK: UploadTransport

    func openSession(for intent: UploadIntent) async throws -> TransportSessionID {
        calls.append(.opened)
        let session = TransportSessionID("session-\(nextSession)")
        nextSession += 1
        sessions[session] = Session(intent: intent)
        return session
    }

    func send(_ transfer: PlannedTransfer,
              in session: TransportSessionID) async throws -> TransferOutcome {
        calls.append(.sent(transfer.chunk))
        guard var state = sessions[session] else { throw TransportError.unknownSession }
        let behavior = nextBehavior(for: transfer.chunk)

        switch behavior {
        case .stall:
            // No answer, and nothing lands. The caller learns nothing either way.
            return .interrupted(transfer.chunk)

        case .landWithoutAnswering:
            // No answer, and the unit lands regardless. The outcome is byte-for-byte the
            // one `.stall` returns, because an absent answer says nothing about the bytes.
            state.units.insert(transfer.chunk)
            state.spans.append(transfer.range)
            sessions[session] = state
            return .interrupted(transfer.chunk)

        case .refuse:
            // An answer, and a negative one. Nothing lands.
            return .refused(transfer.chunk)

        case .succeed, .duplicate:
            state.units.insert(transfer.chunk)
            state.spans.append(transfer.range)
            sessions[session] = state

            deliveredReports.append(transfer.chunk)
            if behavior == .duplicate { deliveredReports.append(transfer.chunk) }
            return .reportedComplete(transfer.chunk)
        }
    }

    func confirmedProgress(in session: TransportSessionID) async throws -> Confirmation {
        calls.append(.asked(session))
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
        calls.append(.finalized(session))
        guard var state = sessions[session] else { throw TransportError.unknownSession }
        guard state.units == Set(state.intent.plan.chunks) else {
            throw TransportError.incompleteUpload
        }
        state.finalized = true
        sessions[session] = state
    }

    /// What this chunk does on this send: whatever is queued for it, else what it is
    /// scripted to do standingly, else the default.
    private func nextBehavior(for chunk: ChunkID) -> Behavior {
        if var waiting = queued[chunk], !waiting.isEmpty {
            let next = waiting.removeFirst()
            queued[chunk] = waiting
            return next
        }
        return behaviors[chunk] ?? defaultBehavior
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
