import DunnageCore

/// Recorded logs, and the phase each one derives.
///
/// One fixture, used by every test that asks whether a derivation survives something —
/// being split, or being written to a disk and read back by a process that was not there
/// when it was written.
enum RecordedLogs {

    struct Scenario {
        let name: String
        let events: [UploadEvent]
        let phase: UploadPhase
    }

    static let upload = UploadID("upload-a")
    static let session = TransportSessionID("session-1")

    static var intent: UploadIntent {
        UploadIntent(upload: upload,
                     destination: DestinationRef("destination-a"),
                     plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    }

    static func report(_ progress: ConfirmedProgress) -> UploadEvent {
        .authorityReported(Confirmation(upload: upload, session: session, progress: progress))
    }

    static var everything: ConfirmedProgress { .chunks(Set(intent.plan.chunks)) }

    static var all: [Scenario] {
        let opened: [UploadEvent] = [.declared(intent), .transportSessionOpened(session)]
        return [
            Scenario(name: "empty log", events: [], phase: .undeclared),
            Scenario(name: "declared only", events: [.declared(intent)], phase: .declared),
            Scenario(name: "session opened", events: opened, phase: .transferring),
            Scenario(name: "transport reported, authority silent",
                     events: opened + [.chunkTransferReported(ChunkID(1))],
                     phase: .transferring),
            Scenario(name: "partial confirmation",
                     events: opened + [report(.chunks([ChunkID(1), ChunkID(3)]))],
                     phase: .transferring),
            Scenario(name: "offset-shaped partial confirmation",
                     events: opened + [report(.offset(ByteOffset(9)))],
                     phase: .transferring),
            Scenario(name: "everything confirmed",
                     events: opened + [report(everything)],
                     phase: .finalizing),
            Scenario(name: "finalized",
                     events: opened + [report(everything), .finalized],
                     phase: .completed),
            Scenario(name: "interrupted mid-transfer, authority silent",
                     events: opened + [.chunkTransferInterrupted(ChunkID(2))],
                     phase: .transferring),
            Scenario(name: "refused mid-transfer, authority silent",
                     events: opened + [.chunkTransferRefused(ChunkID(2))],
                     phase: .transferring),
            Scenario(name: "gave up with what the authority confirmed still on the log",
                     events: opened + [report(.chunks([ChunkID(1), ChunkID(2)])),
                                       .chunkTransferRefused(ChunkID(3)),
                                       report(.chunks([ChunkID(1), ChunkID(2)])),
                                       .abandoned(.retriesExhausted)],
                     phase: .failed),
            Scenario(name: "abandoned mid-transfer",
                     events: opened + [.abandoned(.taskCancelled)],
                     phase: .failed),
            Scenario(name: "premature finalize is rejected and does not stick",
                     events: opened + [.finalized, .chunkTransferReported(ChunkID(2))],
                     phase: .transferring),
            Scenario(name: "authority forgot what it had confirmed",
                     events: opened + [report(everything), report(.chunks([]))],
                     phase: .transferring),
            Scenario(name: "events after completion are absorbed",
                     events: opened + [report(everything), .finalized,
                                       .chunkTransferReported(ChunkID(1)),
                                       .abandoned(.taskCancelled),
                                       .declared(intent)],
                     phase: .completed),
        ]
    }
}
