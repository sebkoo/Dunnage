import DunnageCore

/// The two things inside a `TransportSessionID`, which Core carries whole and only this
/// transport composes and reads (ADR-0006 §2):
///
///     TransportSessionID.rawValue  ==  <ref> "/" <uploadId>
///
/// After a relaunch the driver recovers the identity from the log and asks for confirmed
/// progress with it and nothing else, so the ref the plane needs to name the object key
/// has to be inside it. `parse` is the `parseSession` ADR-0006 §2 assigned to the transport
/// and ADR-0007 §4 moved here.
struct SessionIdentity: Hashable, Sendable {
    let ref: String
    let uploadId: String

    /// The identity `openSession` hands Core: the only place one is created, and it always
    /// creates a well-formed one.
    var composed: TransportSessionID { TransportSessionID(ref + "/" + uploadId) }

    /// Split on the first `/`: everything before it is the ref, everything after it is the
    /// uploadId, whatever it contains. `r/a/b` is ref `r` and uploadId `a/b`, because S3's
    /// upload id is an opaque token and refusing a second separator would encode a guess
    /// about a vendor's format.
    ///
    /// Exactly three inputs throw `TransportError.unrecognisedSession` — no separator, an
    /// empty ref, an empty uploadId — and nothing else does. All three mean one thing: this
    /// transport never minted this string. The list is three and not two only while
    /// ADR-0006 §4's third falsifier holds, that S3 never returns an empty upload id.
    static func parse(_ id: TransportSessionID) throws -> SessionIdentity {
        // This split is total only because no ref the plane accepts contains `/`. The one
        // thing that keeps it so is `testARefContainingASeparatorIsRefused` in
        // `cloud/test/identity.test.ts` — another language, another suite, and nothing a
        // compiler sees connects the two. The rule lives in ADR-0006 §2.
        let raw = id.rawValue
        guard let separator = raw.firstIndex(of: "/") else {
            throw TransportError.unrecognisedSession
        }
        let ref = String(raw[..<separator])
        let uploadId = String(raw[raw.index(after: separator)...])
        guard !ref.isEmpty, !uploadId.isEmpty else {
            throw TransportError.unrecognisedSession
        }
        return SessionIdentity(ref: ref, uploadId: uploadId)
    }
}
