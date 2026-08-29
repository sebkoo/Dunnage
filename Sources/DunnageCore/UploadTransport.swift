// The transport boundary.
//
// Declared in Core, implemented outside it. Core's transition function is pure and never
// calls this; transitions hand back effects as data and a driver executes them.
//
// See docs/adr/0001-transport-boundary-and-confirmed-progress.md.

/// What a transport says about one transfer it was asked to perform.
public enum TransferOutcome: Hashable, Sendable {
    /// The transport says the transfer finished.
    ///
    /// This is an observation about a request, not a statement by the authority about what
    /// it durably holds. Core records it and then goes and asks.
    case reportedComplete(ChunkID)

    /// The transfer did not complete.
    case failed(FailureReason)

    /// No outcome was produced at all.
    ///
    /// A stall is the absence of an answer, not a slow one, so it needs no clock to model.
    /// Whether the bytes landed is unknown, which is exactly the point: only the authority
    /// can settle that.
    case stalled
}

public enum TransportError: Error, Hashable, Sendable {
    /// The authority has no record of this transport operation. An aborted or expired
    /// multipart upload looks like this.
    case unknownSession

    /// Finalization was asked for while the authority does not hold every unit. An
    /// uploaded part is not a completed object.
    case incompleteUpload
}

public protocol UploadTransport: Sendable {
    /// Begin a transport operation for an upload.
    func openSession(for intent: UploadIntent) async throws -> TransportSessionID

    /// Transfer one planned span.
    func send(_ transfer: PlannedTransfer,
              in session: TransportSessionID) async throws -> TransferOutcome

    /// Ask the authority what it durably holds.
    ///
    /// The returned confirmation carries its own semantics: which upload, which transport
    /// operation, and whether the guarantee is set-shaped or offset-shaped. Core does not
    /// decide which; the transport contract does.
    func confirmedProgress(in session: TransportSessionID) async throws -> Confirmation

    /// Ask for the object to be created from what the authority holds.
    func finalize(_ session: TransportSessionID) async throws
}
