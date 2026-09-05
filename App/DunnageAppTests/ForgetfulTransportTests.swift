import XCTest
import DunnageCore
@testable import DunnageTransport
@testable import Dunnage

/// The negative control's own two tier-1 tests: the contract it keeps, and the contrast
/// that makes the difference attributable to the one thing that differs.
///
/// Deterministic (ADR-0007 §2, tier 1): the scripted wire and a canned plane, no session,
/// no socket, no clock. Every wait here is on an event one of the doubles publishes — the
/// wire's next start, the transport's count of the waiters it has stored, the send's own
/// `Task` — and nothing anywhere in this file counts yields or pauses for an interval.
///
/// **Contract, control, contrast, in that order** (spec §7 rider a, 3a2cbbe's shape). The
/// contract test is first because the order is an argument: the control has to be a fair
/// instrument before it is a demonstration, and only then is the difference the third test
/// shows attributable to `confirmedProgress`'s source rather than to some second fault. The
/// control itself — the counter reading 2 after a kill and a relaunch — is tier 2, in
/// `ControlUITests`.
final class ForgetfulTransportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dunnage-forgetful-tests-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: the two arms

    /// One arm of the comparison: a fresh wire, a fresh honest transport, and whichever
    /// transport `UploadModel` would hand the driver over it.
    private struct Arm {
        let driven: any UploadTransport
        let honest: BackgroundSessionTransport
        let wire: ScriptedWire
        let plane: PlaneScript
        let intent: UploadIntent
        let session = TransportSessionID("r/u")

        func transfer(_ ordinal: Int) -> PlannedTransfer {
            let chunk = ChunkID(ordinal)
            return PlannedTransfer(chunk: chunk, range: intent.plan.range(of: chunk)!)
        }
    }

    /// The plane both arms are asked, and the journal of what they asked it. Stateful in
    /// one respect only: the second `complete` is refused as an incomplete complete, so
    /// `finalize`'s named refusal is in the comparison beside its success.
    private actor PlaneScript {
        private(set) var asked: [String] = []
        private var completes = 0

        func answer(_ request: PlaneRequest) -> PlaneResponse {
            asked.append("\(request.method) \(request.path)")
            switch (request.method, request.path) {
            case ("POST", "/uploads"):
                return PlaneResponse(status: 200, body: Data(#"{"uploadId":"u"}"#.utf8))
            case ("POST", "/uploads/r/urls"):
                let entries = (1...3).map { #"{"partNumber":\#($0),"url":"https://x/\#($0)"}"# }
                return PlaneResponse(status: 200,
                                     body: Data(#"{"urls":[\#(entries.joined(separator: ","))]}"#.utf8))
            case ("GET", "/uploads/r/parts"):
                let held = self.held.map(String.init).joined(separator: ",")
                return PlaneResponse(status: 200, body: Data(#"{"parts":[\#(held)]}"#.utf8))
            case ("POST", "/uploads/r/complete"):
                completes += 1
                guard completes > 1 else {
                    return PlaneResponse(status: 200, body: Data(#"{"etag":"e"}"#.utf8))
                }
                return PlaneResponse(status: 400, body: Data(#"{"error":"incomplete upload"}"#.utf8))
            default:
                return PlaneResponse(status: 404, body: Data())
            }
        }

        let held: [Int]
        init(held: [Int]) { self.held = held }
    }

    /// An upload of 12 bytes cut in fours: three chunks, and `/urls` signs three parts.
    private func arm(control: Bool, held: [Int] = []) throws -> Arm {
        let support = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let payload = PayloadRef("payloads/a")
        let file = support.appendingPathComponent(payload.rawValue)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((0..<12).map { UInt8($0) }).write(to: file)

        let plane = PlaneScript(held: held)
        let wire = ScriptedWire()
        let honest = BackgroundSessionTransport(
            plane: CannedPlane { await plane.answer($0) },
            tasks: wire,
            chunkFiles: ChunkFiles(directory: support.appendingPathComponent("chunks", isDirectory: true),
                                   resolve: { support.appendingPathComponent($0.rawValue) }))
        // Through the argument the app reads and the site that reads it, so what these
        // tests measure is the transport `-transport forgetful` installs and never one
        // assembled here.
        let arguments = LaunchArguments.parse(["Dunnage"] + (control ? ["-transport", "forgetful"] : []))
        return Arm(driven: transportForTheDriver(named: arguments.transport, wrapping: honest),
                   honest: honest,
                   wire: wire,
                   plane: plane,
                   intent: UploadIntent(upload: UploadID("a"),
                                        destination: DestinationRef("r"),
                                        payload: payload,
                                        plan: ChunkPlan(totalBytes: 12, chunkSize: 4)))
    }

    // MARK: claim 7 — contract

    /// The forgetful transport keeps the contract it is measured against.
    ///
    /// Both transports are driven through one script and every observable answer is
    /// collected: the identity `openSession` composed, the outcome each completion became,
    /// the tasks created per chunk, the refusal an expired URL produced and the fresh task
    /// the next send made, what the plane was asked, and what `finalize` returned and
    /// refused. `confirmedProgress` is the one call the script never makes, because that is
    /// the fault.
    ///
    /// Every differing row is collected and named, not the first one: evidence naming one
    /// row of eight is worse than evidence naming eight. **A control that also broke
    /// something else would prove nothing about the one thing**, which is why this test is
    /// the first of the three and not an afterthought to them.
    func testTheForgetfulTransportKeepsTheContractItIsMeasuredAgainst() async throws {
        let byTheHonestTransport = try await script(try arm(control: false))
        let byTheControl = try await script(try arm(control: true))

        // A script that collected nothing would make two empty lists, and two empty lists
        // agree. The comparison is only evidence if it read something.
        XCTAssertFalse(byTheHonestTransport.isEmpty,
                       "the script observed nothing, so this comparison read nothing it could compare")
        XCTAssertEqual(byTheHonestTransport.count, byTheControl.count,
                       "the two arms produced different numbers of rows: \(byTheHonestTransport.count) and \(byTheControl.count)")

        var differences: [String] = []
        for (honest, control) in zip(byTheHonestTransport, byTheControl) where honest != control {
            differences.append("'\(honest)' became '\(control)'")
        }
        XCTAssertTrue(differences.isEmpty,
                      "the control differs from the transport it stands in for somewhere the fault is not — \(differences.joined(separator: "; "))")
    }

    // MARK: claim 7 — contrast

    /// After a relaunch-shaped reset the honest transport answers from what the authority
    /// holds, and the control answers from what this process happened to see.
    ///
    /// Two fresh instances, which is what a relaunch leaves: no registry, no waiters, no
    /// remembered completion, and a session identity that came off the log. One wire, one
    /// authority holding parts 1 and 2, one question. The honest transport asks
    /// `GET /uploads/{ref}/parts` and answers `.chunks({1, 2})`; the control asks nothing
    /// and answers `.chunks({})`, because this process reported nothing. **The difference
    /// is the source of the answer, not the diligence of the transport around it.**
    func testAfterARelaunchShapedResetTheHonestTransportAnswersFromWhatTheAuthorityHolds() async throws {
        let honest = try arm(control: false, held: [1, 2])
        let control = try arm(control: true, held: [1, 2])

        let fromTheAuthority = try await honest.driven.confirmedProgress(
            for: honest.intent.upload, in: honest.session)
        let fromThisProcess = try await control.driven.confirmedProgress(
            for: control.intent.upload, in: control.session)

        XCTAssertEqual(fromTheAuthority.progress, .chunks([ChunkID(1), ChunkID(2)]),
                       "the honest transport did not answer with the two parts the authority holds")
        XCTAssertEqual(fromThisProcess.progress, .chunks([]),
                       "the control answered with something this process was never told: a relaunch leaves its memory empty")
        let askedByTheHonestTransport = await honest.plane.asked
        let askedByTheControl = await control.plane.asked
        XCTAssertEqual(askedByTheHonestTransport, ["GET /uploads/r/parts"],
                       "the honest transport did not ask the authority exactly once: \(askedByTheHonestTransport)")
        XCTAssertEqual(askedByTheControl, [],
                       "the control reached the authority, and the whole of its fault is that it does not: \(askedByTheControl)")
    }

    // MARK: the script both arms are driven through

    /// One run of the script, as rows. Everything observable except `confirmedProgress`.
    private func script(_ arm: Arm) async throws -> [String] {
        var rows: [String] = []

        // A task the daemon still holds under a description this transport never wrote.
        _ = await arm.wire.seedPending(description: "a task somebody else named")
        await arm.honest.adopt()
        rows.append("adoption: \(await arm.wire.journal)")

        let session = try await arm.driven.openSession(for: arm.intent)
        rows.append("openSession: \(session.rawValue)")

        rows.append("chunk 1, answered 200: \(try await send(1, of: arm, in: session, answering: .answered(status: 200)))")
        rows.append("chunk 2, expired URL: \(try await send(2, of: arm, in: session, answering: .answered(status: 403)))")
        rows.append("chunk 2, sent again: \(try await send(2, of: arm, in: session, answering: .answered(status: 200), registration: 2))")
        rows.append("chunk 3, no answer: \(try await send(3, of: arm, in: session, answering: .noAnswer))")

        for part in 1...3 {
            rows.append("tasks created for part \(part): \(await arm.wire.puts(part: part))")
        }
        rows.append("the wire was called: \(await arm.wire.journal)")

        for attempt in 1...2 {
            do {
                try await arm.driven.finalize(session)
                rows.append("finalize \(attempt): returned")
            } catch {
                rows.append("finalize \(attempt): \(error)")
            }
        }
        rows.append("the plane was asked: \(await arm.plane.asked)")
        return rows
    }

    /// Hand one chunk over, let the session report `completion` for the task the wire
    /// started for it, and give back the outcome the send returned.
    ///
    /// Both events are awaited, in the order the transport performs them: the wire hands
    /// out the start, and the send then registers a waiter on it. Completing before the
    /// waiter exists would leave the outcome in `unclaimed` and the send awaiting nothing.
    /// `registration` is the transport's cumulative count for the chunk, so the second send
    /// for a chunk asks for the second.
    private func send(_ ordinal: Int,
                      of arm: Arm,
                      in session: TransportSessionID,
                      answering completion: PartTaskCompletion,
                      registration: Int = 1) async throws -> TransferOutcome {
        let sending = Task { try await arm.driven.send(arm.transfer(ordinal), of: arm.intent, in: session) }
        let started = await arm.wire.nextStart()
        await arm.honest.whenRegistered(registration, on: ChunkID(ordinal), of: arm.intent.upload)
        await arm.wire.complete(started, with: completion)
        return try await sending.value
    }
}
