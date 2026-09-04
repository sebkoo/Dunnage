import XCTest

/// Tier 2, simulator evidence (ADR-0007 §2). One of the two tests in this repository that
/// launch an app, and the phase's main claim.
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
/// The bounds and the polls are `StandInUITestCase`'s, and `ControlUITests` takes the same
/// ones: the negative control is this sequence with one launch argument added, so the two
/// are comparable only while there is one definition of every wait.
@MainActor
final class RelaunchUITests: StandInUITestCase {

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
}
