import XCTest

/// The bounds and the polls the tier-2 tests take, in one definition.
///
/// Two tier-2 tests drive the same stand-in through the same sequence and differ in one
/// launch argument, so the sequence lives here and neither test restates it. Two copies of
/// a bound are two bounds, and a wait that drifted between them would make the pair
/// incomparable — which is the whole of what the control is for.
///
/// **Every wait here is a bounded count of tries with a name and a failure message.** No
/// wait in this file is an unconditional pause, a progress estimate or a clock reading: the
/// kill each test performs is sequenced on the stand-in's own report of what it received
/// (spec §1.1).
///
/// It carries no test of its own, so it contributes no name to the enumeration the docs
/// guard reads.
@MainActor
class StandInUITestCase: XCTestCase {

    // MARK: the bounds

    /// One try's bound. A try ends when its answer arrives and satisfies the try's own
    /// condition, and otherwise when this runs out — so a "not yet" costs one try and
    /// nothing else, and the counts below bound each wait whole.
    nonisolated static let tryInterval: TimeInterval = 0.25

    /// Until a control call is answered: 5 s. The stand-in is a local process with nothing
    /// to do, so a call it has not answered in twenty tries is a call it is not going to.
    nonisolated static let controlTries = 20

    /// Until the stand-in lists the upload the app opened: 15 s. It appears when the app's
    /// `POST /uploads` is answered, which is the first thing the driver does.
    nonisolated static let openTries = 60

    /// Until the stand-in reports part 3 received and held: 15 s. This is the wait the kill
    /// is sequenced on, and it is why nothing pauses before `terminate()`.
    nonisolated static let heldTries = 60

    /// Until the relaunched app's phase label exists and is not empty: 15 s. A cold launch
    /// of the app under the runner, and no more.
    nonisolated static let launchTries = 60

    /// Until `upload-phase` reads `completed`: 30 s. The relaunched process asks the
    /// authority, sends the chunks it is not told about, asks again and finalizes; a
    /// handful of round trips to a local stand-in, with margin.
    nonisolated static let completionTries = 120

    nonisolated static func bound(_ tries: Int) -> TimeInterval { Double(tries) * tryInterval }

    // MARK: the waits

    /// The upload the app opened with the stand-in. Exactly one, because the reset each
    /// test performs leaves the stand-in holding none and the test declares one.
    func uploadTheAppOpened(_ base: URL) throws -> String {
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

    func waitUntilPartThreeIsReceivedAndHeld(_ base: URL, _ upload: String) throws {
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

    func receiptMap(_ base: URL, _ upload: String) throws -> Receipts {
        for _ in 0..<Self.controlTries {
            guard let data = ask(request(base, "/_standin/uploads/\(upload)"),
                                 accepting: { status, _ in status == 200 }) else { continue }
            if let map = Receipts(data) { return map }
        }
        XCTFail("the stand-in did not report its receipts within \(Int(Self.bound(Self.controlTries))) s")
        throw Untaken.waitRanOut
    }

    // MARK: the stand-in

    func standInBaseURL() throws -> URL {
        let name = "DUNNAGE_STANDIN_BASE_URL"
        guard let raw = ProcessInfo.processInfo.environment[name], let url = URL(string: raw) else {
            XCTFail("\(name) names the stand-in this test drives, and the runner was given none")
            throw Untaken.noStandIn
        }
        return url
    }

    func request(_ base: URL, _ path: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        // The stand-in's control surface is not a cache-controlled API, and an answer from
        // a cache is not an answer about what it holds now.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    func control(_ base: URL, _ path: String, _ body: [String: Any]) -> Data? {
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
    func ask(_ request: URLRequest,
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

    // MARK: the screen

    /// Every value the screen carries an identifier for, as one line.
    static func screen(of app: XCUIApplication) -> String {
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
    static func label(of app: XCUIApplication, _ identifier: String) -> String {
        let element = app.staticTexts[identifier]
        return element.exists ? element.label : "absent"
    }

    nonisolated static func uploadIds(_ data: Data) -> [String] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let uploads = json?["uploads"] as? [[String: Any]] ?? []
        return uploads.compactMap { $0["uploadId"] as? String }
    }

    enum Untaken: Error { case noStandIn, waitRanOut }
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
final class Taken: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var data: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
