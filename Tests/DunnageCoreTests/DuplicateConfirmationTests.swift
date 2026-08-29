import XCTest
import DunnageCore

/// The same confirmation can arrive twice — a retry of a chunk that had in fact already
/// landed, or a callback the transport simply delivered again.
///
/// The log is append-only, so both arrivals are recorded; dropping one is not available as
/// a repair. Idempotence therefore has to be a property of the fold: folding a confirmation
/// twice must derive exactly the state folding it once derives, and the second fold must
/// not carry the upload any closer to done.
final class DuplicateConfirmationTests: XCTestCase {

    // chunks 1...5, four bytes each
    private let intent = UploadIntent(
        upload: UploadID("upload-a"),
        destination: DestinationRef("destination-a"),
        plan: ChunkPlan(totalBytes: 20, chunkSize: 4))
    private let session = TransportSessionID("session-1")

    private func transfer(_ ordinal: Int) -> PlannedTransfer {
        let chunk = ChunkID(ordinal)
        return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
    }

    private func report(_ progress: ConfirmedProgress,
                        from session: TransportSessionID? = nil) -> UploadEvent {
        .authorityReported(Confirmation(upload: intent.upload,
                                        session: session ?? self.session,
                                        progress: progress))
    }

    private var opened: [UploadEvent] {
        [.declared(intent), .transportSessionOpened(session)]
    }

    /// The events a duplicate is capable of arriving as. A duplicated declaration or a
    /// duplicated session is a different question — the machine rejects those outright,
    /// and `ConfirmationIdentityTests` and the transition matrix already state it.
    private func isDuplicable(_ event: UploadEvent) -> Bool {
        switch event.kind {
        case .authorityReported, .chunkTransferReported:            true
        case .declared, .transportSessionOpened, .chunkTransferRefused,
             .chunkTransferInterrupted, .finalized, .abandoned:     false
        }
    }

    private var logs: [(name: String, events: [UploadEvent])] {
        let everything = ConfirmedProgress.chunks(Set(intent.plan.chunks))
        return [
            ("no confirmation yet", opened),
            ("set-shaped, with a gap",
             opened + [report(.chunks([ChunkID(1), ChunkID(3)]))]),
            ("offset-shaped, ending inside a chunk",
             opened + [report(.offset(ByteOffset(9)))]),
            ("a transport report, then the authority",
             opened + [.chunkTransferReported(ChunkID(1)), report(.chunks([ChunkID(1)]))]),
            ("everything confirmed",
             opened + [report(everything)]),
            ("finalized",
             opened + [report(everything), .finalized]),
            ("the authority forgot what it held, then held it again",
             opened + [report(everything), report(.chunks([])), report(everything)]),
        ]
    }

    func testDuplicateConfirmation_IsIdempotentUnderReplay() async throws {

        // ---- the log a transport that duplicates actually writes ----
        //
        // Not a hand-built sequence: the double is scripted to deliver chunk 1's completion
        // twice, and the log is built from the reports exactly as they came off it.
        let transport = InMemoryTransportDouble(shape: .setShaped)
        let live = try await transport.openSession(for: intent)
        await transport.script(.duplicate, for: ChunkID(1))
        for ordinal in [1, 2] { _ = try await transport.send(transfer(ordinal), in: live) }

        let delivered = await transport.deliveredReports
        XCTAssertEqual(delivered, [ChunkID(1), ChunkID(1), ChunkID(2)],
                       "the double must really duplicate, or this proves nothing")

        let confirmation = try await transport.confirmedProgress(in: live)
        let asDelivered: [UploadEvent] =
            [.declared(intent), .transportSessionOpened(live)]
            + delivered.map(UploadEvent.chunkTransferReported)
            + [.authorityReported(confirmation), .authorityReported(confirmation)]
        let deduplicated: [UploadEvent] =
            [.declared(intent), .transportSessionOpened(live),
             .chunkTransferReported(ChunkID(1)), .chunkTransferReported(ChunkID(2)),
             .authorityReported(confirmation)]

        XCTAssertEqual(UploadTransition.replay(asDelivered),
                       UploadTransition.replay(deduplicated),
                       "a duplicating transport must derive the state a quiet one derives")

        // ---- the property, over every log and every position in it ----
        for log in logs {
            let once = UploadTransition.replay(log.events)

            for index in log.events.indices where isDuplicable(log.events[index]) {
                var doubled = log.events
                doubled.insert(log.events[index], at: index)

                XCTAssertEqual(UploadTransition.replay(doubled), once,
                               "\(log.name): duplicating event \(index) changed the state it derives")
            }
        }

        // ---- the second fold moves nothing toward done ----
        //
        // A set that is folded twice is the set the authority named, not a set that grew,
        // and an offset folded twice is where the authority said the prefix ends, not twice
        // as far along it.
        for progress in [ConfirmedProgress.chunks([ChunkID(1), ChunkID(2)]),
                         .offset(ByteOffset(8))] {
            let twice = UploadTransition.replay(opened + [report(progress), report(progress)])

            guard case .transferring(_, _, let confirmed, _) = twice else {
                XCTFail("\(progress): two partial confirmations are not a complete upload")
                continue
            }
            XCTAssertEqual(confirmed, progress,
                           "\(progress): the second fold moved confirmed progress")
            XCTAssertEqual(ResumePlan.derive(for: intent, given: confirmed).transfers.map(\.chunk),
                           [ChunkID(3), ChunkID(4), ChunkID(5)],
                           "\(progress): the second fold changed what is left to send")
        }

        // ---- and it asks for the object to be created exactly once ----
        let everything = ConfirmedProgress.chunks(Set(intent.plan.chunks))
        let finalizing = UploadTransition.replay(opened + [report(everything)])

        guard case .accepted(let after, let effects) =
                UploadTransition.apply(report(everything), to: finalizing) else {
            return XCTFail("a confirmation that arrives twice is still this upload's own")
        }
        XCTAssertEqual(after, finalizing,
                       "a full confirmation folded twice is a full confirmation folded once")
        XCTAssertEqual(effects, [],
                       "finalization is asked for once; the duplicate asks for nothing")
    }

    /// The thesis, restated under duplication. Redundant transfer is bounded by the
    /// unconfirmed set, so a duplicate may well schedule an unconfirmed chunk again — but a
    /// chunk the authority has confirmed is not sent because a confirmation arrived twice.
    func testDuplicateConfirmationNeverSchedulesAConfirmedChunk() {
        let held: Set<ChunkID> = [ChunkID(1), ChunkID(2), ChunkID(4)]
        var state = UploadTransition.replay(opened + [report(.chunks(held))])

        for round in 1...3 {
            guard case .accepted(let next, let effects) =
                    UploadTransition.apply(report(.chunks(held)), to: state) else {
                XCTFail("fold \(round): this upload's own confirmation must be applied")
                continue
            }
            state = next

            guard case .send(let transfers, _, _)? = effects.first else {
                XCTFail("fold \(round): the unconfirmed chunks are still outstanding")
                continue
            }
            XCTAssertTrue(Set(transfers.map(\.chunk)).isDisjoint(with: held),
                          "fold \(round): a duplicate rescheduled a chunk the authority holds")
            XCTAssertEqual(transfers.map(\.chunk), [ChunkID(3), ChunkID(5)],
                           "fold \(round): the outstanding set is the same on every fold")
        }
    }
}
