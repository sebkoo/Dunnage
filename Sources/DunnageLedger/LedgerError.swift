import DunnageCore

/// What was wrong with one record.
///
/// The two cases are the distinction ADR-0004 §2 exists to protect, on the payload side of
/// the framing. A record that is complete and *means* something this binary does not have
/// is not the same as a record that is complete and is not a record at all — and neither of
/// them is a torn tail, which is decided before a payload is read.
public enum RecordFault: Error, Hashable, Sendable {
    /// Complete, well formed, and naming something this binary does not have. A newer build
    /// wrote it.
    ///
    /// `field` is where it was named — a key, or the event whose fields were being read —
    /// and `token` is the thing there is no meaning for. The refusal says what it could not
    /// read, not merely that it could not.
    case unknownToken(field: String, token: String)

    /// Complete, and not what the format says.
    case malformed(detail: String)
}

/// What was wrong with a ledger, as opposed to with one record in it.
public enum LedgerError: Error, Hashable, Sendable {
    /// The file does not begin with a header this module writes.
    case unrecognizedFormat(header: String)

    /// The header names a format version this binary does not have. Reading it as the
    /// version this binary does have would be a guess.
    case unsupportedFormatVersion(Int)

    /// A frame that is present and is not a frame. Distinct from a record that ends before
    /// it is whole: the bytes were there, so nothing was truncated here.
    case malformedFrame(atByteOffset: Int)

    /// A record ends before it is whole.
    case incompleteRecord(atByteOffset: Int)

    /// The frame was whole and the payload could not be read.
    case unreadableRecord(upload: UploadID, sequence: LogSequence, fault: RecordFault)

    /// A file in the ledger directory that this module did not write. Refused rather than
    /// stepped over, on the same grounds as everything else here.
    case unrecognizedLedgerFile(name: String)

    /// The upload identifier does not fit in a filename.
    case uploadIdentifierTooLongForAFilename(UploadID)

    /// The filesystem refused to create the ledger.
    case couldNotCreateLedger(UploadID)
}
