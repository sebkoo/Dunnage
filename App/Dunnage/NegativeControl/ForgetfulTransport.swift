#if DEBUG
import DunnageCore
import DunnageTransport

/// The failure mode the thesis removes, kept working on purpose. **Never "fixed".**
///
/// One method differs. `openSession`, `send` and `finalize` forward to the transport this
/// wraps, verbatim; `send` additionally remembers the chunks whose outcome was
/// `.reportedComplete`. `confirmedProgress` answers from that memory and never calls the
/// wrapped transport, so it never reaches `GET /uploads/{ref}/parts`. That is the whole of
/// the fault: a report is an observation about a request, and this transport reads it as a
/// statement by the authority — ADR-0001 §3's collapse, made to work.
///
/// **The memory is this process's, and it is one set for the process rather than one per
/// session.** Nothing is written down, so a relaunch starts empty, and that is exactly why
/// the control re-sends after a kill: the driver asks, the answer is "nothing", and every
/// chunk of the plan is planned again. The coarser scope is deliberate. Keying the memory
/// by session would keep two uploads in one process from contaminating each other, and a
/// control more careful than the bug it stands for understates the bug: the fault being
/// demonstrated is "a report is read as the authority's word", and a transport that made
/// that mistake would not also be scrupulous about which operation it made it for. What
/// bounds the answer against a plan is Core's own reading —
/// `ConfirmedProgress.confirmedChunks(in:)` takes a set-shaped answer against the plan it
/// is asked about — so the intersection is something this control gets for nothing, and
/// never a care it takes.
///
/// It lives in the app target under `#if DEBUG`, behind `-transport forgetful`, and never
/// in `DunnageTransport` (spec §7 rider b): a control the tests need is not a thing a
/// release build ships. Nothing outside this directory names the type.
///
/// It is never "fixed". If this transport stops re-sending a part the authority already
/// holds, the control has been broken and `BackgroundSessionTransport` has nothing left to
/// be measured against.
actor ForgetfulTransport: UploadTransport {

    /// The honest transport, whole. Three of the four calls are its own answers.
    private let honest: BackgroundSessionTransport

    /// The chunks a completion reported to this process, and the whole of what this
    /// transport will call confirmed. One set for the process, for the reason above.
    private var remembered: Set<ChunkID> = []

    init(wrapping honest: BackgroundSessionTransport) {
        self.honest = honest
    }

    /// Forwarded.
    func openSession(for intent: UploadIntent) async throws -> TransportSessionID {
        try await honest.openSession(for: intent)
    }

    /// Forwarded, and remembered. The report is the honest transport's own; reading it as
    /// progress is this transport's doing, and it happens below and not here.
    func send(_ transfer: PlannedTransfer,
              of intent: UploadIntent,
              in session: TransportSessionID) async throws -> TransferOutcome {
        let outcome = try await honest.send(transfer, of: intent, in: session)
        if case .reportedComplete(let chunk) = outcome { remembered.insert(chunk) }
        return outcome
    }

    /// **The one method that differs, and the whole of the fault.** It answers from the
    /// reports this process saw and never calls the wrapped transport, so `GET
    /// /uploads/{ref}/parts` is never asked and the authority is never consulted. After a
    /// relaunch the memory is empty, the answer is "nothing", and every chunk of the plan
    /// is planned again — including the parts the authority already holds.
    func confirmedProgress(for upload: UploadID,
                           in session: TransportSessionID) async throws -> Confirmation {
        Confirmation(upload: upload, session: session, progress: .chunks(remembered))
    }

    /// Forwarded.
    func finalize(_ session: TransportSessionID) async throws {
        try await honest.finalize(session)
    }
}

/// The value `-transport` is given to install the control.
let forgetfulTransportName = "forgetful"

/// The transport the driver is handed: the control wrapping the honest one when the
/// installed transport is named `forgetful`, and the honest one otherwise.
///
/// The decision lives here, beside the control, so that no file outside this directory
/// names the type — which is what the release-symbol check and the source grep in
/// `.github/workflows/ci.yml` assert. `UploadModel` asks this and keeps its own
/// `BackgroundSessionTransport` reference either way: `adopt()` and `inFlightChunks(of:)`
/// are the real transport's, so the screen and the registry are unchanged and the control
/// corrupts exactly one answer.
func transportForTheDriver(named name: String?,
                           wrapping honest: BackgroundSessionTransport) -> any UploadTransport {
    guard name == forgetfulTransportName else { return honest }
    return ForgetfulTransport(wrapping: honest)
}
#endif
