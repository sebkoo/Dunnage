import DunnageCore
import DunnageDriver

/// One order of events, written by a log and a transport that would each otherwise know
/// only their own.
///
/// "An answer is on the log before the next transfer begins" is a claim about the order
/// between two objects, and neither of them can make it alone. Both write here, so the
/// interleaving is something a test reads rather than something it infers from two separate
/// records that never met.
actor DriverJournal {
    enum Entry: Hashable, Sendable {
        /// Written after the append returned, so the entry means the event is durable.
        case appended(UploadEvent)
        /// Written before the transfer is handed over, so the entry means it has begun.
        case sent(ChunkID)
        /// Written after the wait elapsed, so the entry means it was taken and not merely
        /// asked for.
        case waited(Duration)
    }

    private(set) var entries: [Entry] = []

    func record(_ entry: Entry) { entries.append(entry) }
}

/// The in-memory log, noting each append in a shared journal. Nothing else about it differs.
struct JournallingEventLog: UploadEventLog {
    let wrapped: InMemoryEventLog
    let journal: DriverJournal

    @discardableResult
    func append(_ events: [UploadEvent], for upload: UploadID) async throws -> [EventRecord] {
        let records = try await wrapped.append(events, for: upload)
        for event in events { await journal.record(.appended(event)) }
        return records
    }

    func records(for upload: UploadID) async throws -> [EventRecord] {
        try await wrapped.records(for: upload)
    }

    func uploads() async throws -> [UploadID] {
        try await wrapped.uploads()
    }
}

/// The suite's clock, noting each wait it granted in a shared journal. Nothing else about
/// it differs.
struct JournallingClock: DriverClock {
    let wrapped: VirtualClock
    let journal: DriverJournal

    func wait(for duration: Duration) async throws {
        try await wrapped.wait(for: duration)
        await journal.record(.waited(duration))
    }
}

/// The in-memory transport, noting each transfer in a shared journal. Nothing else about it
/// differs, and in particular it invents no answers of its own.
struct JournallingTransport: UploadTransport {
    let wrapped: InMemoryTransportDouble
    let journal: DriverJournal

    func openSession(for intent: UploadIntent) async throws -> TransportSessionID {
        try await wrapped.openSession(for: intent)
    }

    func send(_ transfer: PlannedTransfer,
              in session: TransportSessionID) async throws -> TransferOutcome {
        await journal.record(.sent(transfer.chunk))
        return try await wrapped.send(transfer, in: session)
    }

    func confirmedProgress(in session: TransportSessionID) async throws -> Confirmation {
        try await wrapped.confirmedProgress(in: session)
    }

    func finalize(_ session: TransportSessionID) async throws {
        try await wrapped.finalize(session)
    }
}
