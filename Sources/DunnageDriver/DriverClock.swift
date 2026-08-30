// Where time enters this package.
//
// Core computes how long the next attempt should wait and hands that back as data on a
// `send` effect; the driver is the thing that waits. ADR-0001 recorded that Core introduces
// no clock, and that note still holds literally: this protocol is declared here, in the
// driver's module, and Core neither knows about it nor gains anything from it.
//
// See docs/adr/0005-the-driver-and-the-clock-it-waits-behind.md §4.

/// The driver's clock.
///
/// One method, because the driver has one need: to not proceed for a while. There is no
/// `now`, deliberately. A driver that can read the present time can compute a duration of
/// its own, and every duration the driver computes is a number Core did not sanction.
public protocol DriverClock: Sendable {
    /// Do not come back for `duration`. A non-positive duration returns at once.
    ///
    /// Cancellation ends the wait by throwing. A driver whose task is cancelled stops; it
    /// does not conclude anything about the upload, and it writes nothing.
    func wait(for duration: Duration) async throws
}

/// The clock that reads real time.
///
/// The only conformance in this package that actually waits, and the only production
/// behaviour in the module with no test behind it: a test of a real sleep is a wall-clock
/// wait, and this repository does not have one. It is three lines, and it is here so that
/// the boundary above has a use rather than only a fake.
///
/// `Task.sleep(for:)` runs on the continuous clock, which keeps counting while the process
/// is suspended. That is the right one for a backoff: an endpoint that asked to be left
/// alone for a minute has been left alone for a minute whether or not this process was
/// running.
public struct SystemClock: DriverClock {
    public init() {}

    public func wait(for duration: Duration) async throws {
        guard duration > .zero else { return }
        try await Task.sleep(for: duration)
    }
}
