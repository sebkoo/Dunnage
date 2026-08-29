// The transport boundary.
//
// Declared in Core, implemented outside it. Core's transition function is pure and never
// calls this; transitions hand back effects as data and a driver executes them.
//
// See docs/adr/0001-transport-boundary-and-confirmed-progress.md.

/// What a transport says about one transfer it was asked to perform.
///
/// Three answers, and the distance between the two negative ones is the point. "The answer
/// was no" settles that this transfer did not become a unit the authority holds. "No answer
/// arrived" settles nothing at all. A transport boundary that returned one `failed` case for
/// both would hand Core a dropped connection and a rejected request as the same fact, and
/// Core would have to guess which it was.
///
/// See docs/adr/0002-interruption-is-not-a-failure.md.
public enum TransferOutcome: Hashable, Sendable {
    /// The transport says the transfer finished.
    ///
    /// This is an observation about a request, not a statement by the authority about what
    /// it durably holds. Core records it and then goes and asks.
    case reportedComplete(ChunkID)

    /// The transport answered, and the answer was no. This transfer did not become a unit
    /// the authority holds, and the transport is in a position to say so.
    case refused(ChunkID)

    /// No answer arrived. A dropped connection and a stall say the same thing — nothing —
    /// so they are one case and not two, and neither needs a clock to model: an
    /// interruption is the absence of an answer, not a slow one.
    ///
    /// Whether the bytes landed is unknown, which is exactly the point: only the authority
    /// can settle that.
    case interrupted(ChunkID)
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
