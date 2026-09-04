import XCTest

/// The negative control, tier 2: the same kill and relaunch, driven through a transport
/// that trusts its own reports.
///
/// The sequence below is `RelaunchUITests`'s, step for step, with `-transport forgetful`
/// added to the launch arguments and nothing else changed — the same reset, the same sample
/// payload, the same `hold(part: 3, mode: "after-store")`, the same wait on the stand-in's
/// report, the same `terminate()`, the same `release`, the same relaunch. The bounds and
/// the polls are `StandInUITestCase`'s, so there is one definition of every wait and the
/// two runs are comparable.
///
/// **The counter is what makes the negative visible.** The relaunched process asks its
/// transport what the authority holds; the control answers out of a memory that died with
/// the first process, and every chunk of the plan is planned again. So the receipt map
/// reads **2** for the parts the authority already held before the kill, where the test
/// under claim 4 — the same sequence over the honest transport — asserts every count is 1.
/// **This is the one place in the repository where a re-send is expected**: everywhere else
/// a count above 1 is the failure this phase exists to remove, and here it is the evidence.
///
/// The control is never "fixed". If this run stops re-sending a part the authority already
/// holds, the control has been broken and the honest transport has nothing left to be
/// measured against.
@MainActor
final class ControlUITests: StandInUITestCase {

    func testWithATransportThatTrustsItsOwnReportsTheRelaunchResendsWhatTheAuthorityHolds() throws {
        let base = try standInBaseURL()
        XCTAssertNotNil(control(base, "/_standin/reset", ["reset": true]),
                        "the stand-in did not answer POST /_standin/reset")
        XCTAssertNotNil(control(base, "/_standin/hold", ["part": 3, "mode": "after-store"]),
                        "the stand-in did not answer POST /_standin/hold for part 3")

        let app = XCUIApplication()
        app.launchArguments = [
            "-standin-base-url", base.absoluteString,
            "-token", "dunnage-ui-test",
            "-quiet-after", "600",
            // The one difference from claim 4's run, and the whole of the experiment.
            "-transport", "forgetful",
        ]
        app.launch()

        let start = app.buttons["use-sample-payload"]
        XCTAssertTrue(start.waitForExistence(timeout: Self.bound(Self.launchTries)),
                      "the app did not come up within \(Int(Self.bound(Self.launchTries))) s")
        start.tap()

        let upload = try uploadTheAppOpened(base)
        try waitUntilPartThreeIsReceivedAndHeld(base, upload)

        app.terminate()

        XCTAssertNotNil(control(base, "/_standin/release", ["part": 3]),
                        "the stand-in did not answer POST /_standin/release for part 3")

        app.launch()

        let phase = app.staticTexts["upload-phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: Self.bound(Self.launchTries)),
                      "the relaunched app did not come up within \(Int(Self.bound(Self.launchTries))) s")
        XCTAssertFalse(phase.label.isEmpty,
                       "the relaunched app did not come up within \(Int(Self.bound(Self.launchTries))) s")

        let lastExit = Self.label(of: app, "last-exit")
        print("last-exit after the terminate: \(lastExit)")
        XCTContext.runActivity(named: "last-exit read '\(lastExit)'") { _ in }

        let completed = app.staticTexts.element(
            matching: NSPredicate(format: "identifier == %@ AND label == %@",
                                  "upload-phase", "completed"))
        let reached = completed.waitForExistence(timeout: Self.bound(Self.completionTries))
        print("the relaunched screen reads: \(Self.screen(of: app))")
        XCTAssertTrue(reached,
                      "the upload did not complete within \(Int(Self.bound(Self.completionTries))) s")

        // The shape, not a fixed map: which parts read 2 depends on how far the first
        // process got before the kill, and the sequence guarantees only that the authority
        // had answered for parts 1 and 2 by the time part 3 was received and held. What is
        // asserted is that every part the authority already held was sent again, and that
        // the plan's four parts are all there — the same instrument claim 4's test reads
        // the map with, so two tier-2 runs differing in one launch argument differ in one
        // assertion and not in how the map is read. The whole map is in every message.
        let receipts = try receiptMap(base, upload)
        XCTAssertEqual(receipts.puts["1"], 2,
                       "part 1 was received \(receipts.puts["1"] ?? 0) times, not the 2 a transport that trusts its own reports produces — the whole map is \(receipts.puts), completes \(receipts.completes)")
        XCTAssertEqual(receipts.puts["2"], 2,
                       "part 2 was received \(receipts.puts["2"] ?? 0) times, not the 2 a transport that trusts its own reports produces — the whole map is \(receipts.puts), completes \(receipts.completes)")
        XCTAssertEqual(receipts.puts.count, 4,
                       "the authority holds \(receipts.puts.count) parts, not the four the plan named — the whole map is \(receipts.puts), completes \(receipts.completes)")
        XCTAssertEqual(receipts.completes, 1,
                       "the authority was asked to complete \(receipts.completes) times — a second complete is a finalize the driver had no cause to ask for")
        print("receipts after the control's relaunch: \(receipts.puts), completes \(receipts.completes)")
    }
}
