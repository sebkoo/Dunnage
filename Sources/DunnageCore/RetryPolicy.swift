// How hard to try, how long to wait, and what counts as a try.
//
// Pure data and pure functions. Core computes how long the next attempt should wait and
// hands that back as part of an effect; it never waits, never runs a timer and never reads
// a clock. Where a driver has to wait, it does so behind its own injected clock — that
// boundary is outside Core on purpose.
//
// See docs/adr/0003-what-an-attempt-is-and-where-time-enters.md.

/// How many times a chunk may be refused before the upload is given up on, and how long a
/// retry waits first.
///
/// This lives on `UploadIntent`, which means it is written to the log by the declaration
/// and comes back with it. A policy passed alongside the log instead would be a second
/// input to the fold, and replaying the same log under a different policy would derive a
/// different upload.
public struct RetryPolicy: Hashable, Sendable {

    /// How many refusals one chunk may collect. Reaching it is what exhaustion means.
    public let maxAttemptsPerChunk: Int

    /// The wait before the second attempt. Each further attempt doubles it.
    public let initialBackoff: Duration

    /// The longest a retry ever waits, however many attempts have gone before it.
    public let maximumBackoff: Duration

    public init(maxAttemptsPerChunk: Int, initialBackoff: Duration, maximumBackoff: Duration) {
        precondition(maxAttemptsPerChunk >= 1, "a policy that allows no attempt sends nothing")
        precondition(initialBackoff >= .zero, "a backoff does not run backwards")
        precondition(maximumBackoff >= initialBackoff, "the cap is not below the first wait")
        self.maxAttemptsPerChunk = maxAttemptsPerChunk
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
    }

    public static let `default` = RetryPolicy(maxAttemptsPerChunk: 3,
                                              initialBackoff: .seconds(1),
                                              maximumBackoff: .seconds(60))

    /// How long to wait before attempt number `attempt`, counting from 1.
    ///
    /// Doubling, capped, and deterministic: there is no jitter, because jitter needs
    /// entropy and Core has none. Spreading a thundering herd is a driver's problem, at the
    /// boundary where randomness is allowed to live.
    public func backoff(beforeAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return .zero }        // nothing has been refused yet
        var wait = initialBackoff
        for _ in 2..<attempt {
            guard wait < maximumBackoff else { return maximumBackoff }
            wait = wait * 2
        }
        return min(wait, maximumBackoff)
    }

    /// Whether a chunk that has spent `attempts` has any left.
    public func isExhausted(after attempts: Int) -> Bool { attempts >= maxAttemptsPerChunk }
}

/// What each chunk has spent, derived from the log like everything else.
///
/// **An attempt is a refusal:** the transport answered, and the answer was no. An
/// interruption is not an attempt. No answer arrived, so nothing was learned about the
/// chunk, and charging it would let a flaky network exhaust the budget of chunks that were
/// never in trouble. That is the rule ADR-0002 fixed, spelled out here where it is spent.
///
/// A chunk is charged at most once between one answer from the authority and the next.
/// Core hands a chunk to a transport exactly once per answer — `.send` is only ever
/// produced by settling a confirmation — so a second refusal naming the same chunk before
/// the authority has spoken again is one refusal delivered twice, and it costs nothing. The
/// log cannot tell those two apart on its own, and this is the rule that means it does not
/// have to.
public struct Attempts: Hashable, Sendable {

    private let spent: [ChunkID: Int]
    private let chargedSinceTheAuthorityAnswered: Set<ChunkID>

    public init() {
        self.spent = [:]
        self.chargedSinceTheAuthorityAnswered = []
    }

    private init(spent: [ChunkID: Int], charged: Set<ChunkID>) {
        self.spent = spent
        self.chargedSinceTheAuthorityAnswered = charged
    }

    /// How many attempts `chunk` has spent.
    public func count(for chunk: ChunkID) -> Int { spent[chunk] ?? 0 }

    /// Charge a refusal, unless this chunk has already been charged since the authority
    /// last answered.
    public func charging(_ chunk: ChunkID) -> Attempts {
        guard !chargedSinceTheAuthorityAnswered.contains(chunk) else { return self }
        var next = spent
        next[chunk, default: 0] += 1
        return Attempts(spent: next,
                        charged: chargedSinceTheAuthorityAnswered.union([chunk]))
    }

    /// The authority answered. Whatever it did or did not confirm, the next transfer of a
    /// chunk is a new attempt and can be charged again.
    public func afterTheAuthorityAnswered() -> Attempts {
        Attempts(spent: spent, charged: [])
    }

    /// The most any of `chunks` has spent — which is the attempt the next send will be
    /// making, once one is added to it.
    public func highest(among chunks: some Sequence<ChunkID>) -> Int {
        chunks.reduce(0) { max($0, count(for: $1)) }
    }
}
