# Repository policy

## Thesis (do not weaken)

This library never re-sends a chunk after that chunk has been positively confirmed by the
transport authority. Redundant transfer is bounded by the set of unconfirmed in-flight
chunks, under the transport's stated contract.

Three things are distinct and must never be collapsed:

1. **Background URLSession execution** — durable scheduling across eligible background
   lifecycle events. The system continues transfers while the app is not running and
   relaunches it to deliver events.
2. **The IETF HTTP resumable upload protocol used by URLSession** — byte-wise
   resumption, offset-shaped. Requires the server to participate. With a background
   configuration the resumption is handled automatically, but only when the server
   speaks the protocol.
3. **S3 multipart** — set-shaped. The authority reports which part numbers it holds, not
   a resumable byte offset.

None of the three implies the others. Background execution alone does not define durable
application progress or reconcile it against an arbitrary backend contract. Any comment,
symbol, doc line, or test name that collapses these is wrong. Correct it; don't soften it.

**What "confirmed" means.** A confirmation is authoritative only under the transport's
stated identity and payload contract. It must identify both the upload and the confirmed
unit under that contract; a confirmation belonging to one upload identity or transport
operation is never silently applied to another. Core must never treat "the request
returned success" as equivalent to "this exact upload unit is durably known to exist."
The two are different claims: on S3, re-uploading the same part number overwrites the previous part, so *part 5
exists* and *the payload this upload intended is the one stored as part 5* are not the same
statement. Where the transport cannot make the stronger claim, the invariant must be
written against the weaker one, and the gap recorded in an ADR.

## Architecture

- Core is pure: no networking, no disk, no clock, no randomness. Time, entropy and I/O
  enter only through injected protocols.
- The append-only event log is the single source of truth. State and the resume view are
  derived from it. A checkpoint may exist later as a performance cache; it must be
  reconstructible from the log and disposable. Never a parallel authority.
- Never mutate or drop an event to repair state. Append a corrective event.
- The transition table is total: every (state, event) pair resolves explicitly, including
  `.rejected(reason)`. No `default:` in the transition switch — the point is that adding
  an enum case becomes a compiler error. Compiler exhaustiveness guards the structure; a
  runtime transition-matrix test guards the semantics. Both, not either.
- Transitions are pure functions returning (state, [effect]). Effects are data; a driver
  executes them. Never perform I/O inside a transition.
- Terminal states are absorbing. No event leaves `.completed` or `.failed`.
- Core asks the transport boundary for confirmed progress. It never infers progress from
  bytes it handed to a transport.
- Confirmed progress carries its own semantics, not a bare number. "Part 5 exists" and
  "bytes 0 through 5 are contiguous" are different contracts, and Core must not collapse
  them. They are cases of one sum type, never two optional fields on a struct: a shape
  that makes "both" and "neither" representable forces a runtime rule for states the
  transport contract says cannot exist.
- No speculative abstraction. An architectural boundary is allowed when it isolates a
  platform boundary or preserves a required invariant, even with one implementation today.
  Anything else needs two concrete in-tree use cases.

## Testing

- Every invariant has at least one named test; the name states the invariant, not the
  method. Related edge cases may add more tests — do not compress them to hit a count.
- Red before green on behavioral invariants: the test is observed failing, with output,
  before the code that satisfies it. Where a test cannot go red without artificial
  sabotage — compiler-enforced exhaustiveness, a property test over a correct pure
  helper — record why in one line and move on. Never manufacture a failure to satisfy
  the ritual.
- Deterministic only: virtual clock, no sleeps, no wall-clock waits, no timers.
- CI must not require AWS access keys, SSO sessions, or stored cloud credentials for unit
  or contract validation. `swift test`, `cdk synth`, and contract tests run with none.
- Fakes live in the test target and are themselves covered by a contract test.
- Keep negative controls: at least one test demonstrates the failure mode the thesis
  claims to remove. It is never "fixed."
- Logical failure injection is not lifecycle validation. A simulated process death does
  not stand in for a real SIGKILL, and no test name may imply it does.

## Failure handling

- A failing test is evidence. Never weaken, skip, or delete it for a green build. Deleting
  one requires a commit explaining why the invariant was wrong.
- A red suite halts the task. Fix or revert; never stack changes on red.
- Unresolved uncertainty is written down as UNVERIFIED in the commit body or an ADR, never
  guessed away.

## Git

- One behavioral or architectural decision per commit. It may touch many files. Never one
  commit per file; never two decisions in one commit.
- Mechanical change: subject only. Behavioral or architectural change: subject plus a
  short body saying why the code exists, not how it was produced.
- No automated tool-attribution trailers on public commits. Do not fabricate authorship,
  ownership, or provenance. Do not modify source or history to falsely claim human-only
  authorship.
- The commit that completes a phase updates the progress table in `README.md` in the same
  commit. A status that can drift from the repository is worse than no status.

## Done

The invariant is named and falsifiable in the commit; its named test was seen red, then
green; the full suite passes; no test was weakened or removed; every new (state, event)
pair appears in the totality test; every production behavior in the diff is justified by a
test, an invariant, or a documented architectural decision; decisions constraining later
phases are in an ADR.

"It builds" satisfies none of these and is never reported as done.
