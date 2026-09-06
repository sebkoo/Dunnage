import XCTest

/// The bounds and the polls the tier-2 tests take, in one definition.
///
/// Two tier-2 tests drive the same stand-in through the same sequence and differ in one
/// launch argument, so the sequence lives here and neither test restates it. Two copies of
/// a bound are two bounds, and a wait that drifted between them would make the pair
/// incomparable — which is the whole of what the control is for.
///
/// **Every wait here is bounded, named, and says what it saw when its bound ran out.** A
/// wait's bound is a deadline — `bound(tries)`, wall-clock — and `tries` is the number of
/// questions that deadline is spelled as; the two now agree, where a count of loop
/// iterations once read as a count of questions asked. No wait here is a progress estimate
/// or a pause for progress: a wait ends the moment its answer arrives, the only clock any
/// of them reads is its own deadline and the space it leaves between two questions, and the
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

    // MARK: the session

    /// The session every question here is asked over. Its own, and not `URLSession.shared`.
    ///
    /// A wait cannot state a property of networking it does not own, and `shared`'s defaults
    /// have already had to be worked around once in this file: `request(_:_:)` sets a cache
    /// policy per call because the shared cache must not answer for the stand-in. Each value
    /// below has a reason, because a value with no reason is a guess.
    ///
    /// - `ephemeral`: nothing here is worth a disk cache or a cookie store, and an answer
    ///   out of either is not an answer about what the stand-in holds now.
    /// - `urlCache = nil`: what the per-request policy says once per call, said once here as
    ///   a property of the session instead.
    /// - `httpMaximumConnectionsPerHost = 1` **states the property `ask`'s cancel creates;
    ///   it does not create it.** A try owns its request until it answers or is cancelled,
    ///   so at most one is ever outstanding, and this line is that written down. It is not a
    ///   guard: a loop that later stopped cancelling would quietly serialise its requests
    ///   behind this limit rather than announce the change. **The invariant lives in `ask`,
    ///   and whoever changes that loop has to come back here.**
    nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    // MARK: the waits

    /// The upload the app opened with the stand-in. Exactly one, because the reset each
    /// test performs leaves the stand-in holding none and the test declares one.
    func uploadTheAppOpened(_ base: URL) throws -> String {
        let seen = Seen()
        let deadline = Date().addingTimeInterval(Self.bound(Self.openTries))
        var questions = 0
        while questions < Self.openTries, Date() < deadline {
            questions += 1
            let asked = Date()
            switch ask(request(base, "/_standin/uploads"), until: deadline, into: seen,
                       accepting: { status, data in
                           status == 200 && Self.uploadIds(data).count == 1
                       }) {
            case .accepted(let data): return Self.uploadIds(data)[0]
            case .rejected:           pace(from: asked, until: deadline)
            case .unanswered:         continue   // the deadline; the loop's own guard ends it
            }
        }
        XCTFail("the app did not open an upload with the stand-in within \(Int(Self.bound(Self.openTries))) s "
              + "(\(questions) of \(Self.openTries) questions); the stand-in answered \(seen.described)")
        throw Untaken.waitRanOut
    }

    func waitUntilPartThreeIsReceivedAndHeld(_ base: URL, _ upload: String) throws {
        let seen = Seen()
        let deadline = Date().addingTimeInterval(Self.bound(Self.heldTries))
        var questions = 0
        while questions < Self.heldTries, Date() < deadline {
            questions += 1
            let asked = Date()
            switch ask(request(base, "/_standin/uploads/\(upload)"), until: deadline, into: seen,
                       accepting: { status, data in
                           guard status == 200, let map = Receipts(data) else { return false }
                           return map.puts["3"] == 1 && map.held.contains(3)
                       }) {
            case .accepted:   return
            case .rejected:   pace(from: asked, until: deadline)
            case .unanswered: continue   // the deadline; the loop's own guard ends it
            }
        }
        XCTFail("part 3 was not received and held within \(Int(Self.bound(Self.heldTries))) s "
              + "(\(questions) of \(Self.heldTries) questions); the stand-in answered \(seen.described)")
        throw Untaken.waitRanOut
    }

    func receiptMap(_ base: URL, _ upload: String) throws -> Receipts {
        let seen = Seen()
        let deadline = Date().addingTimeInterval(Self.bound(Self.controlTries))
        var questions = 0
        while questions < Self.controlTries, Date() < deadline {
            questions += 1
            let asked = Date()
            switch ask(request(base, "/_standin/uploads/\(upload)"), until: deadline, into: seen,
                       accepting: { status, _ in status == 200 }) {
            case .accepted(let data):
                if let map = Receipts(data) { return map }
                pace(from: asked, until: deadline)
            case .rejected:   pace(from: asked, until: deadline)
            case .unanswered: continue   // the deadline; the loop's own guard ends it
            }
        }
        XCTFail("the stand-in did not report its receipts within \(Int(Self.bound(Self.controlTries))) s "
              + "(\(questions) of \(Self.controlTries) questions); the stand-in answered \(seen.described)")
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

    /// The one wait here that answers with `nil` rather than throwing, because its callers
    /// assert on the answer. That is an implementation difference and not a licence to be
    /// mute: it reports what it last saw on the way out, exactly as the three above do, and
    /// the caller's own assertion still says which call it was.
    func control(_ base: URL, _ path: String, _ body: [String: Any]) -> Data? {
        var post = request(base, path)
        post.httpMethod = "POST"
        post.httpBody = try? JSONSerialization.data(withJSONObject: body)
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let seen = Seen()
        let deadline = Date().addingTimeInterval(Self.bound(Self.controlTries))
        var questions = 0
        while questions < Self.controlTries, Date() < deadline {
            questions += 1
            let asked = Date()
            switch ask(post, until: deadline, into: seen,
                       accepting: { status, _ in status == 200 }) {
            case .accepted(let data): return data
            case .rejected:           pace(from: asked, until: deadline)
            case .unanswered:         continue   // the deadline; the loop's own guard ends it
            }
        }
        XCTFail("POST \(path) was not answered within \(Int(Self.bound(Self.controlTries))) s "
              + "(\(questions) of \(Self.controlTries) questions); the stand-in answered \(seen.described)")
        return nil
    }

    /// What one try came back with.
    enum Answer {
        /// An answer arrived and the wait's condition took it.
        case accepted(Data)
        /// An answer arrived and the condition said no. The question is spent; the wait may
        /// ask another.
        case rejected
        /// The wait's deadline passed with nothing back, and the request was cancelled.
        case unanswered
    }

    /// One try: one question, and its answer.
    ///
    /// The request is issued once and owned until it answers — a response *or* an error,
    /// and either is recorded — or until `deadline`, at which point it is cancelled so that
    /// nothing this try started is left running for the tries after it.
    ///
    /// **The cancel is what makes a wait's count mean what it says.** A try that walked away
    /// from its request at a bound of its own left it running, and the next try started
    /// another beside it. A stand-in answering a little later than that bound was then
    /// accepted by no try while answering every one of them, and the abandoned requests
    /// piled up behind the session's per-host limit until most tries were never attempts at
    /// all — a wait of twenty questions asking four. Both halves of that are gone: a
    /// request is owned to its answer, and `Self.session` states the one-at-a-time property
    /// this ownership creates.
    func ask(_ request: URLRequest,
             until deadline: Date,
             into seen: Seen,
             accepting accept: @escaping @Sendable (Int, Data) -> Bool) -> Answer {
        let answered = XCTestExpectation(description: "the stand-in answered \(request.url?.path ?? "")")
        let taken = Taken()
        let task = Self.session.dataTask(with: request) { data, response, error in
            // Fulfilled on every outcome, not only an acceptable one: the wait has to be
            // able to tell an answer it did not like from no answer at all, and it cannot
            // do that if only the answers it liked wake it.
            //
            // **Deferred, and the ordering is the invariant.** The fulfill runs after
            // `taken.data` has been written, so the waiter cannot wake between the
            // condition accepting an answer and that answer being there to return. An
            // explicit fulfill moved any earlier lets the waiter read `taken.data` as nil
            // and report `.rejected` for an answer the condition took — this function's own
            // defect wearing another face. **Whoever un-defers this has to put the write
            // first.**
            defer { answered.fulfill() }
            if let error {
                // Our own cancel is not the stand-in refusing. It is this question reaching
                // the deadline, and `ranOut` has already counted it.
                let code = (error as NSError).code
                if code != NSURLErrorCancelled { seen.refused(error.localizedDescription) }
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                seen.refused("an answer that was not an HTTP response")
                return
            }
            seen.answered(http.statusCode, data)
            guard accept(http.statusCode, data) else { return }
            taken.data = data
        }
        task.resume()

        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0,
              XCTWaiter().wait(for: [answered], timeout: remaining) == .completed else {
            task.cancel()
            seen.ranOut()
            return .unanswered
        }
        if let data = taken.data { return .accepted(data) }
        return .rejected
    }

    /// The space between one question and the next.
    ///
    /// A stand-in that answers "not yet" in a millisecond would otherwise be asked as fast
    /// as the loop runs, and a wait spelled as sixty questions would be over in sixty
    /// milliseconds. This is a rate on questions and never a wait for progress: it delays
    /// no answer the wait would have taken — an acceptable one returns from `ask` the moment
    /// it arrives — and it never runs past the wait's own deadline.
    func pace(from asked: Date, until deadline: Date) {
        let next = min(asked.addingTimeInterval(Self.tryInterval), deadline)
        let remaining = next.timeIntervalSinceNow
        guard remaining > 0 else { return }
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "between two questions")],
                             timeout: remaining)
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

    /// One line, in a fixed order. A map has no order of its own and a failure message read
    /// against another failure message needs one, for the reason the ledger's written form
    /// sorts a set before writing it.
    var described: String {
        let counts = puts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return "puts [\(counts.joined(separator: ", "))], completes \(completes), held \(held.sorted())"
    }
}

/// What a wait was told, for the message it prints when its bound runs out.
///
/// A wait that names only what was absent cannot tell three different failures apart, and
/// this repository has now been bitten by two of them: a stand-in that answered and whose
/// answer did not satisfy the condition, a stand-in the transport could not reach at all,
/// and a stand-in slower than the wait was willing to be. Every outcome is recorded —
/// including the answers the wait's own condition rejected, which are the interesting ones,
/// and including the errors, which `ask` used to discard.
///
/// The lock is the checking, which is why the conformance is unchecked, and it is the same
/// lock `Taken` carries for the same reason: the handler runs on the session's queue. An
/// answer arriving just after the deadline is recorded late and may reach the message. That
/// is what "the last answer seen" means, and it is not something the message can be wrong
/// about.
final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int?
    private var body: Data?
    private var answers = 0
    private var refusals = 0
    private var lastRefusal: String?
    private var deadlined = 0

    /// An HTTP answer arrived, whatever the wait's condition then made of it.
    func answered(_ status: Int, _ body: Data) {
        lock.withLock {
            self.status = status
            self.body = body
            self.answers += 1
        }
    }

    /// The transport answered instead of the stand-in. Never our own cancel, which is a
    /// question reaching the deadline and is counted as one.
    func refused(_ what: String) {
        lock.withLock {
            self.refusals += 1
            self.lastRefusal = what
        }
    }

    /// A question reached the wait's deadline with nothing back, and was cancelled.
    func ranOut() {
        lock.withLock { self.deadlined += 1 }
    }

    /// Always printable, and it names which of the three happened. A wait that saw nothing
    /// says so rather than printing an empty map, which would read like an answer.
    var described: String {
        lock.withLock {
            if let status, let body {
                let text = Receipts(body)?.described
                    ?? String(decoding: body.prefix(200), as: UTF8.self)
                let line = "\(answers) time(s), the last status \(status): \(text)"
                guard refusals > 0 || deadlined > 0 else { return line }
                return line + " (\(refusals) refused, \(deadlined) unanswered)"
            }
            if refusals > 0 {
                return "nothing usable: \(refusals) refused, the last \(lastRefusal ?? "for no stated reason")"
            }
            return "nothing at all: \(deadlined) question(s) reached the deadline with no answer"
        }
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
