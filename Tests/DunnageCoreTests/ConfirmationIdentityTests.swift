import XCTest
import DunnageCore

/// A confirmation is authoritative only under the transport's stated identity contract.
/// It names an upload and a transport operation, and it is evidence about those and
/// nothing else.
final class ConfirmationIdentityTests: XCTestCase {

    private let session = TransportSessionID("session-1")
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))

    private var transferring: UploadMachineState {
        UploadTransition.replay([.declared(intent), .transportSessionOpened(session)])
    }
    private var everything: ConfirmedProgress { .chunks(Set(intent.plan.chunks)) }

    /// Two uploads are two uploads. Applying one's confirmation to the other would mark
    /// chunks confirmed that this upload's authority has never mentioned, and the thesis
    /// would then decline to send them — forever.
    func testConfirmationNamingAnotherUploadIsNeverApplied() {
        let foreign = Confirmation(upload: UploadID("upload-b"),
                                   session: session,
                                   progress: everything)

        guard case .rejected(let reason) =
                UploadTransition.apply(.authorityReported(foreign), to: transferring) else {
            return XCTFail("another upload's confirmation was applied to this one")
        }
        XCTAssertEqual(reason, .confirmationForAnotherUpload)
    }

    /// Part numbers are scoped to a transport operation. On S3 they are scoped to an
    /// uploadId, so "part 3" from one operation is not evidence about part 3 of another —
    /// which is exactly what an authority that forgot a session and was reopened produces.
    func testConfirmationFromAnotherTransportOperationIsNeverApplied() {
        let superseded = Confirmation(upload: intent.upload,
                                      session: TransportSessionID("session-2"),
                                      progress: everything)

        guard case .rejected(let reason) =
                UploadTransition.apply(.authorityReported(superseded), to: transferring) else {
            return XCTFail("a confirmation from another transport operation was applied")
        }
        XCTAssertEqual(reason, .confirmationFromAnotherTransportSession)
    }

    /// The matching case still works, so the guards reject foreign statements rather than
    /// all statements.
    func testConfirmationNamingThisUploadAndThisOperationIsApplied() {
        let mine = Confirmation(upload: intent.upload, session: session, progress: everything)

        guard case .accepted(let next, _) =
                UploadTransition.apply(.authorityReported(mine), to: transferring) else {
            return XCTFail("this upload's own confirmation must be applied")
        }
        XCTAssertEqual(next.phase, .finalizing)
    }
}
