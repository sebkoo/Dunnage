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
