import DunnageCore

/// An in-memory `UploadEventLog`. Lives in the test target, and is itself covered by a
/// contract test — a fake that quietly disagrees with the protocol proves nothing.
actor InMemoryEventLog: UploadEventLog {
    private var storage: [UploadID: [EventRecord]] = [:]
    private var order: [UploadID] = []

    @discardableResult
    func append(_ events: [UploadEvent], for upload: UploadID) async throws -> [EventRecord] {
        if storage[upload] == nil { order.append(upload) }

        // Sequences continue from what is already there. Existing records are read, never
        // rewritten: the only mutation this type performs is growing the array.
        var existing = storage[upload] ?? []
        let appended = events.enumerated().map { offset, event in
            EventRecord(sequence: LogSequence(existing.count + offset + 1), event: event)
        }
        existing.append(contentsOf: appended)
        storage[upload] = existing
        return appended
    }

    func records(for upload: UploadID) async throws -> [EventRecord] {
        storage[upload] ?? []
    }

    /// In first-append order, so enumeration is deterministic. A real store would have its
    /// own ordering; the contract only requires each upload to appear once.
    func uploads() async throws -> [UploadID] {
        order
    }
}
