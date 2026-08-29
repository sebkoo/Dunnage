// The persistence boundary.
//
// The log is the single source of truth. State and the resume view are derived from it by
// replay; nothing else is authoritative. There is deliberately no update and no delete on
// this protocol — append-only is a property of the shape, not a rule someone remembers.
// A state that turns out to be wrong is repaired by appending a corrective event.

/// Position in one upload's log. Assigned by the log, starting at 1, with no gaps.
public struct LogSequence: Hashable, Comparable, Sendable {
    public let value: Int
    public init(_ value: Int) {
        precondition(value >= 1, "log sequences start at 1")
        self.value = value
    }
    public static func < (lhs: LogSequence, rhs: LogSequence) -> Bool { lhs.value < rhs.value }
}

/// One event as the log stored it.
public struct EventRecord: Hashable, Sendable {
    public let sequence: LogSequence
    public let event: UploadEvent

    public init(sequence: LogSequence, event: UploadEvent) {
        self.sequence = sequence
        self.event = event
    }
}

public protocol UploadEventLog: Sendable {
    /// Append events for one upload, in the order given. Returns them as stored, carrying
    /// the sequence numbers the log assigned.
    @discardableResult
    func append(_ events: [UploadEvent], for upload: UploadID) async throws -> [EventRecord]

    /// Every record for one upload, in append order. An upload the log has never seen has
    /// no records; that is not an error.
    func records(for upload: UploadID) async throws -> [EventRecord]

    /// Every upload the log holds anything for. This is what a cold start enumerates.
    func uploads() async throws -> [UploadID]
}
