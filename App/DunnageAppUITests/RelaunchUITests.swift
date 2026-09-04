import XCTest

/// Tier 2, simulator evidence (ADR-0007 §2). The only test in this repository that launches
/// an app.
///
/// **What the kill is evidence for:** process B derives its state from a file process A
/// left, shares no memory with A, and asks the authority before it sends. The registry, the
/// waiters, the unclaimed completions and the URL process A minted all went with it.
///
/// **What it is not evidence for:** which signal `terminate()` delivers and whether the
/// daemon keeps or cancels a killed app's tasks (O-14), whether
/// `timeoutIntervalForResource` counts while suspended (O-13), whether the daemon can read
/// the copy the app made (O-15) — nor suspension, jetsam, relaunch for events, force-quit,
/// radio or power, none of which a simulator run reaches. The name says the simulator
/// terminated the process and says nothing more, which is ADR-0007 §2's naming rule.
///
/// **Every wait here is a bounded count of tries with a name and a failure message.** No
/// wait in this file is an unconditional pause, a progress estimate or a clock reading: the
/// kill is sequenced on the stand-in's own report of what it received (spec §1.1).
@MainActor
final class RelaunchUITests: XCTestCase {

    // MARK: the bounds

    /// One try's bound. A try ends when its answer arrives and satisfies the try's own
    /// condition, and otherwise when this runs out — so a "not yet" costs one try and
    /// nothing else, and the counts below bound each wait whole.
    nonisolated private static let tryInterval: TimeInterval = 0.25

    /// Until a control call is answered: 5 s. The stand-in is a local process with nothing
    /// to do, so a call it has not answered in twenty tries is a call it is not going to.
    nonisolated private static let controlTries = 20

    /// Until the stand-in lists the upload the app opened: 15 s. It appears when the app's
    /// `POST /uploads` is answered, which is the first thing the driver does.
    nonisolated private static let openTries = 60

    /// Until the stand-in reports part 3 received and held: 15 s. This is the wait the kill
    /// is sequenced on, and it is why nothing pauses before `terminate()`.
    nonisolated private static let heldTries = 60

    /// Until the relaunched app's phase label exists and is not empty: 15 s. A cold launch
    /// of the app under the runner, and no more.
    nonisolated private static let launchTries = 60

    /// Until `upload-phase` reads `completed`: 30 s. The relaunched process asks the
    /// authority, sends the one chunk it does not hold, asks again and finalizes; four
    /// round trips to a local stand-in, with margin.
    nonisolated private static let completionTries = 120

    nonisolated private static func bound(_ tries: Int) -> TimeInterval { Double(tries) * tryInterval }

    // MARK: the test

    func testAfterTheSimulatorTerminatedTheAppMidTransferTheRelaunchResendsNothingTheAuthorityConfirmed() throws {
        let base = try standInBaseURL()
        XCTAssertNotNil(control(base, "/_standin/reset", ["reset": true]),
                        "the stand-in did not answer POST /_standin/reset")
        // `after-store` and not `before-store`: the bytes are stored — so the authority
        // holds part 3 and `/parts` says so — and only the answer is withheld. That is what
        // makes the kill land on a PUT the authority has already received, which is the
        // case the claim is about. `before-store` is the device harness's (spec §3.3).
        XCTAssertNotNil(control(base, "/_standin/hold", ["part": 3, "mode": "after-store"]),
                        "the stand-in did not answer POST /_standin/hold for part 3")

        let app = XCUIApplication()
        app.launchArguments = [
            "-standin-base-url", base.absoluteString,
            "-token", "dunnage-ui-test",
            // Large enough that no driver timeout fires inside this test: every wait here
            // is the test's own bounded poll, and never the driver's (spec §4.4).
            "-quiet-after", "600",
        ]
        app.launch()

        let start = app.buttons["use-sample-payload"]
        XCTAssertTrue(start.waitForExistence(timeout: Self.bound(Self.launchTries)),
                      "the app did not come up within \(Int(Self.bound(Self.launchTries))) s")
        start.tap()

        let upload = try uploadTheAppOpened(base)
        try waitUntilPartThreeIsReceivedAndHeld(base, upload)

        // The kill. The PUT for part 3 is unanswered at this moment, and what the daemon
        // does with the task is O-14 — the claim below does not rest on either answer.
        app.terminate()

        XCTAssertNotNil(control(base, "/_standin/release", ["part": 3]),
                        "the stand-in did not answer POST /_standin/release for part 3")

        app.launch()

        let phase = app.staticTexts["upload-phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: Self.bound(Self.launchTries)),
                      "the relaunched app did not come up within \(Int(Self.bound(Self.launchTries))) s")
        XCTAssertFalse(phase.label.isEmpty,
                       "the relaunched app did not come up within \(Int(Self.bound(Self.launchTries))) s")

        // Evidence only when present. A process killed before `applicationWillTerminate`
        // ran and a hook that never runs leave the same missing file, so nothing is read
        // off an absence here or anywhere else (ADR-0007 O-14). It is recorded either way.
        let lastExit = Self.label(of: app, "last-exit")
        print("last-exit after the terminate: \(lastExit)")
        XCTContext.runActivity(named: "last-exit read '\(lastExit)'") { _ in }

        let completed = app.staticTexts.element(
            matching: NSPredicate(format: "identifier == %@ AND label == %@",
                                  "upload-phase", "completed"))
        let reached = completed.waitForExistence(timeout: Self.bound(Self.completionTries))
        // Printed either way, and before the assertion, so a red on the simulator names
        // what the relaunched screen actually said (spec §10 rider b).
        print("the relaunched screen reads: \(Self.screen(of: app))")
        XCTAssertTrue(reached,
                      "the upload did not complete within \(Int(Self.bound(Self.completionTries))) s")

        // §4.3's precondition is what makes this a statement about the log: the screen is
        // derived by replaying the ledger plus the transport's in-flight set, and this
        // process was told nothing about part 3 by anything but that file.
        XCTAssertEqual(Self.label(of: app, "chunk-3-status"), "confirmed",
                       "the relaunched app does not show part 3 confirmed")

        // The completion is the occasion; the receipt map is the evidence. Without this
        // read the test proves only that the relaunched upload finishes — a resume that
        // re-sent a part the authority already held would still be green, and that is the
        // negative this phase exists to remove.
        let receipts = try receiptMap(base, upload)
        let resent = receipts.puts.filter { $0.value != 1 }.keys.sorted()
        XCTAssertTrue(resent.isEmpty,
                      "parts \(resent) were not received exactly once — the whole map is \(receipts.puts), completes \(receipts.completes)")
        XCTAssertEqual(receipts.puts.count, 4,
                       "the authority holds \(receipts.puts.count) parts, not the four the plan named — the whole map is \(receipts.puts)")
        XCTAssertEqual(receipts.completes, 1,
                       "the authority was asked to complete \(receipts.completes) times — a second complete is a finalize the driver had no cause to ask for")
        print("receipts after the relaunch: \(receipts.puts), completes \(receipts.completes)")
    }

    // MARK: the waits

    /// The upload the app opened with the stand-in. Exactly one, because the reset above
    /// left the stand-in holding none and this test declares one.
    private func uploadTheAppOpened(_ base: URL) throws -> String {
        for _ in 0..<Self.openTries {
            guard let data = ask(request(base, "/_standin/uploads"),
                                 accepting: { status, data in
                                     status == 200 && Self.uploadIds(data).count == 1
                                 }) else { continue }
            return Self.uploadIds(data)[0]
        }
        XCTFail("the app did not open an upload with the stand-in within \(Int(Self.bound(Self.openTries))) s")
        throw Untaken.waitRanOut
    }

    private func waitUntilPartThreeIsReceivedAndHeld(_ base: URL, _ upload: String) throws {
        for _ in 0..<Self.heldTries {
            let answered = ask(request(base, "/_standin/uploads/\(upload)"),
                               accepting: { status, data in
                                   guard status == 200, let map = Receipts(data) else { return false }
                                   return map.puts["3"] == 1 && map.held.contains(3)
                               })
            if answered != nil { return }
        }
        XCTFail("part 3 was not received and held within \(Int(Self.bound(Self.heldTries))) s")
        throw Untaken.waitRanOut
    }

    private func receiptMap(_ base: URL, _ upload: String) throws -> Receipts {
        for _ in 0..<Self.controlTries {
            guard let data = ask(request(base, "/_standin/uploads/\(upload)"),
                                 accepting: { status, _ in status == 200 }) else { continue }
            if let map = Receipts(data) { return map }
        }
        XCTFail("the stand-in did not report its receipts within \(Int(Self.bound(Self.controlTries))) s")
        throw Untaken.waitRanOut
    }

    // MARK: the stand-in

    private func standInBaseURL() throws -> URL {
        let name = "DUNNAGE_STANDIN_BASE_URL"
        guard let raw = ProcessInfo.processInfo.environment[name], let url = URL(string: raw) else {
            XCTFail("\(name) names the stand-in this test drives, and the runner was given none")
            throw Untaken.noStandIn
        }
        return url
    }

    private func request(_ base: URL, _ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        // The stand-in's control surface is not a cache-controlled API, and an answer from
        // a cache is not an answer about what it holds now.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func control(_ base: URL, _ path: String, _ body: [String: Any]) -> Data? {
        var post = request(base, path)
        post.httpMethod = "POST"
        post.httpBody = try? JSONSerialization.data(withJSONObject: body)
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for _ in 0..<Self.controlTries {
            if let data = ask(post, accepting: { status, _ in status == 200 }) { return data }
        }
        return nil
    }

    /// One try. The request is issued and its answer awaited; the try ends when an answer
    /// arrives that `accepting` takes, and otherwise when `tryInterval` runs out. Nothing
    /// here pauses: the wait ends on an event or on the try's own bound, and the caller's
    /// count is what bounds the whole wait.
    private func ask(_ request: URLRequest,
                     accepting accept: @escaping @Sendable (Int, Data) -> Bool) -> Data? {
        let answered = XCTestExpectation(description: "the stand-in answered \(request.url?.path ?? "")")
        let taken = Taken()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, let data else { return }
            guard accept(http.statusCode, data) else { return }
            taken.data = data
            answered.fulfill()
        }.resume()
        guard XCTWaiter().wait(for: [answered], timeout: Self.tryInterval) == .completed else {
            return nil
        }
        return taken.data
    }

    /// Every value the screen carries an identifier for, as one line.
    private static func screen(of app: XCUIApplication) -> String {
        (["upload-phase", "driver-note", "last-exit"] + (1...4).map { "chunk-\($0)-status" })
            .map { "\($0)=\(label(of: app, $0))" }
            .joined(separator: " | ")
    }

    /// The label under `identifier`, or `absent`.
    ///
    /// Reading `label` off an element that is not on the screen raises and ends the test
    /// there, taking with it the assertion that was about to be made. A red that names the
    /// claim is worth more than a red that names a missing element, so the absence is a
    /// value here and the assertion is what reports it.
    private static func label(of app: XCUIApplication, _ identifier: String) -> String {
        let element = app.staticTexts[identifier]
        return element.exists ? element.label : "absent"
    }

    nonisolated private static func uploadIds(_ data: Data) -> [String] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let uploads = json?["uploads"] as? [[String: Any]] ?? []
        return uploads.compactMap { $0["uploadId"] as? String }
    }

    private enum Untaken: Error { case noStandIn, waitRanOut }
}

/// `GET /_standin/uploads/{id}`: what the authority received, how many times, and which
/// parts it is still withholding an answer for.
struct Receipts {
    let puts: [String: Int]
    let completes: Int
    let held: [Int]

    init?(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let puts = json["puts"] as? [String: Int],
              let completes = json["completes"] as? Int else { return nil }
        self.puts = puts
        self.completes = completes
        self.held = json["held"] as? [Int] ?? []
    }
}

/// A box for the one value a URLSession callback hands back across a thread boundary. The
/// lock is the checking, which is why the conformance is unchecked.
private final class Taken: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var data: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
