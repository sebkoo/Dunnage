import Foundation
import DunnageDriver

/// The clock this suite runs on.
///
/// A wait elapses when a test says it may, and never otherwise. There is no timeline and no
/// `now`: nothing here needs one, because every ordering this suite asserts is an ordering
/// between *actions* — a wait taken before a transfer began — and not between instants. So
/// no test in this suite is slower because a backoff is long, and none of them can be wrong
/// because a machine was busy.
///
/// It parks nothing. A waiting task spins on `Task.yield()` until its wait is granted or its
/// task is cancelled. That is a deliberate limit on what a fake is allowed to be: a
/// continuation held across a cancellation is concurrency code, and a fake whose own
/// correctness needs an argument makes every test standing on it worth less. Cancellation
/// here is `Task.checkCancellation()` and nothing else.
///
/// A wait for a duration no test granted therefore never returns. That is not an oversight;
/// it is how the driver's timeout is held open in tests that are not about the timeout.
final class VirtualClock: DriverClock, @unchecked Sendable {

    private let lock = NSLock()
    private var grants: [Duration: Int] = [:]
    private var asked: [Duration] = []
    private var taken: [Duration] = []

    init() {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: what the suite drives it with

    /// Let a wait of exactly `duration` elapse, `times` times. Grants are consumed, so a
    /// test that grants one wait and a driver that takes two is a test that hangs rather
    /// than one that passes.
    func grant(_ duration: Duration, times: Int = 1) {
        locked { grants[duration, default: 0] += times }
    }

    /// Every wait the driver asked for, in order, whether or not it elapsed.
    var waitsRequested: [Duration] { locked { asked } }

    /// Every wait that ran to completion. A wait abandoned because its task was cancelled is
    /// absent, which is what makes this the sequence of waits actually taken.
    var waitsTaken: [Duration] { locked { taken } }

    // MARK: DriverClock

    func wait(for duration: Duration) async throws {
        locked { asked.append(duration) }

        // Still a wait, and still recorded as taken. "Honouring it is not optional" has to
        // mean something when the value Core computed happens to be zero, and no test should
        // have to grant the wait before the first attempt.
        guard duration > .zero else {
            locked { taken.append(duration) }
            return
        }

        while true {
            try Task.checkCancellation()   // a wait nobody needs any more is abandoned here
            if locked({ consumeGrant(duration) }) { break }
            await Task.yield()
        }
        locked { taken.append(duration) }
    }

    /// Caller holds the lock.
    private func consumeGrant(_ duration: Duration) -> Bool {
        guard let remaining = grants[duration], remaining > 0 else { return false }
        grants[duration] = remaining - 1
        return true
    }
}

/// A transfer that never answers.
///
/// Cancellation is the only thing that ends it, which is exactly what makes the caller's own
/// timeout the thing under test. No clock and no sleep: this is silence, not slowness, and
/// the two are not the same claim.
enum Silence {
    static func untilCancelled() async throws -> Never {
        while true {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}
