# ADR-0009 — Replacing a transport operation the authority no longer has

- **Status:** accepted
- **Date:** 2026-09-05
- **Scope:** Core's event alphabet and transition table, the ledger's written form for the
  new event, the driver's reading of two thrown errors, and the transport's reading of a 404
  from `finalize`. Nothing is deployed. No AWS account is touched.
- **Builds on:** ADR-0001 §2, whose identity scoping §3 below applies twice. ADR-0002, whose
  distinction between a refusal and an interruption §4 keeps. ADR-0003 §1, whose rule about
  where exhaustion is decided §4 depends on, and §5, whose "giving up is Core's conclusion"
  §1 keeps. ADR-0005 §8, whose sentence §4 scopes, and ADR-0005 O-10, which closes here.
- **Supersedes:** ADR-0005 §8's *a thrown error becomes no event*, in exactly the two cases
  §4 names; its next sentences, about what a `send` that throws does, stand. ADR-0006 §7's
  *4b decides the recovery* and its "Deliberately not decided" bullet *No recovery from an
  operation the authority no longer has*. ADR-0007's cost *Two ways to be unable to move
  remain*. And the phase-4b design spec's §12 row for `README.md` row 4b, in one respect:
  the miscount corrected there lands in this document's own commit, because two ADRs carry
  the same miscount and fixing two of three sites would leave the inconsistency this commit
  exists to remove; the row's status and its full rewording stay the landing commit's, as
  §12 has them.

## Context

Two documents have been waiting on this one.

ADR-0005 O-10 recorded that an authority which has forgotten a transport operation leaves an
upload that is not failed and cannot move: `confirmedProgress` throws, the driver appends
nothing and stops (ADR-0005 §8), and every later run asks, throws and stops again. ADR-0006
§7 gave that exposure a size — the bucket's seven-day lifecycle rule aborts an operation
nobody will complete, so this repository's own configuration produces O-10 on a schedule —
and assigned the recovery here. ADR-0007 §8 added a second way in: an identity this
transport never minted strands an upload the same way, under a different error.

ADR-0001 §2 refused to decide what replacing an operation means until there was a
demonstrated need, and the transition table still refuses one with
`transportSessionAlreadyOpen`. There are now two demonstrated needs, which is the condition
that refusal set.

The record precedes the code for the reason ADR-0006 §1 gave, in a smaller way. The rows,
the ledger's written form, the driver's mapping and the transport's reading land in three
later commits, and a reader of any one of them sees a fragment of one decision. The decision
is here.

## Decision

### 1. One event, and the three things it is not

```swift
case transportSessionLost(TransportSessionID)
```

*The authority no longer has this transport operation.*

ADR-0006 §3 fixed what this case must not be, and it is none of them.

- **Not a `TransferOutcome`.** It says nothing about a chunk, and no chunk event is written
  for it. `TransferOutcome`'s three cases are answers about one transfer; this is an answer
  about the operation every transfer was going to belong to.
- **Not an interruption.** An interruption is the absence of an answer about a chunk whose
  transfer was attempted. No transfer was attempted here, and recording one would put a
  claim about a chunk on the log that nothing made.
- **Never an abandonment.** Giving up is Core's conclusion, reached against a budget derived
  from the log (ADR-0003 §5), and this is not giving up: the upload continues, in another
  operation. `.abandoned` stays the only event that reaches a terminal phase.

It is a fourth thing — an event about the transport operation itself. The alphabet did not
have one because until now an operation was opened and never lost.

**It carries the identity it is about**, for the reason `Confirmation` carries one. A loss is
evidence about the operation it names and about nothing else, and a stale loss replayed off
the log must not drop an operation opened after it.

### 2. The rows, and why `.declared`

```
(.transferring(intent, session, _, _), .transportSessionLost(id))  id == session
    -> .accepted(.declared(intent: intent), [.openTransportSession(intent)])
(.finalizing(intent, session, _, _),   .transportSessionLost(id))  id == session
    -> .accepted(.declared(intent: intent), [.openTransportSession(intent)])

(.transferring, .transportSessionLost)  id != session -> .rejected(.lossNamesAnotherTransportSession)
(.finalizing,   .transportSessionLost)  id != session -> .rejected(.lossNamesAnotherTransportSession)
(.undeclared,   .transportSessionLost)                -> .rejected(.uploadNotDeclared)
(.declared,     .transportSessionLost)                -> .rejected(.noTransportSession)
```

The two terminal rows need no edit: `(.completed, _)` and `(.failed, _)` already absorb
every event, and a new case is absorbed too.

`.declared` and not a new phase. After a loss the intent is on record and no transport
operation is open, which is exactly what `.declared` already means, and the row
`(.declared, .transportSessionOpened)` already does the rest — it enters `.transferring`
with `confirmed: nil` and asks the authority before anything is sent. Nothing about a
replacement needs a state the machine did not have.

`.declared(intent:)` carries neither a confirmation nor a tally, so choosing it as these
rows' target and §3's *the replacement inherits nothing* are one decision and not two.
Carrying the tally across would need a new phase, not a different row.

### 3. The replacement inherits nothing, and that is ADR-0001 §2 twice

**The confirmation.** S3 part numbers are scoped to a multipart `uploadId`, so part 3 of a
dead operation and part 3 of its replacement are unrelated facts — which is the sentence
ADR-0001 §2 already makes about confirmations, applied to the operation as a whole. Carrying
the old confirmed set across would schedule nothing for chunks the new authority does not
hold, and the upload would finalize over parts that do not exist. That failure is kept
working on purpose as this phase's negative control.

**The tally.** An attempt is a refusal (ADR-0003 §1), and a refusal collected against an
operation that no longer exists may have been caused by its not existing: when the authority
aborts an operation with parts in flight, those PUTs are answered with an error, each becomes
`.refused`, and each charges the budget. Carrying them into the replacement would punish the
new operation for the old one's death, and an upload whose last refusals were all *this
operation is gone* would be abandoned on arrival. Refusals scoped to a dead operation are not
evidence about the live one, for the same reason its confirmations are not.

The price of that reading is O-18 below, and it is stated there rather than hedged here.

### 4. The driver's two-error mapping, and the sentence of ADR-0005 §8 it scopes

```
TransportError.unknownSession        the authority has no record of this operation
TransportError.unrecognisedSession   this transport never minted this identity
```

Thrown from `confirmedProgress` or from `finalize`, each becomes exactly one
`transportSessionLost(session)`, appended before the fold, and the fold asks for a
replacement. Every other thrown error still becomes no event and the round still stops,
which is ADR-0005 §8 unchanged everywhere else.

This is a mapping and not a conclusion. The driver already maps a `TransferOutcome` to an
event; it now maps two error cases the same way, and the event says what the transport said.
The synthesis ADR-0002 forbids is inventing a chunk-level fact from something that is not one,
and no chunk appears anywhere in this event.

**`send` is left alone**, and the argument rests on where exhaustion is decided.
`.abandon(.retriesExhausted)` is produced only by `settle`; an ask precedes every settle,
because `.send` is only ever produced by settling a confirmation; and an ask against a dead
operation throws before `settle` runs. So a dead operation's refused PUTs can charge chunks
and can never exhaust one, and the loss is discovered by the ask that always comes next.
Mapping inside `send` would add a second path to the same event for no case the first path
misses.

That makes ADR-0003 §1's rule about where exhaustion is decided load-bearing again, in a
place it was not written for. It is named here so the dependency is visible from both ends:
moving exhaustion out of `settle` would break this section, not merely change it.

### 5. What redundant transfer is bounded by after a replacement

Everything the dead operation held is sent again.

The thesis is untouched, and the reason is its own clause: *redundant transfer is bounded by
the set of unconfirmed in-flight chunks, **under the transport's stated contract***. Under
the replacement's contract nothing is confirmed, because the authority holds nothing under
that `uploadId`, so no chunk this upload sends has been positively confirmed by the authority
it is sending to.

That clause does real work here for the first time. It is a bound per operation and not a
bound on bytes across an upload's life, and this document says so rather than leaving a
reader to take phase 1's claim more widely than it was written.

The parts the dead operation held keep costing storage until the seven-day rule aborts them.
That is ADR-0005 O-8's shape with a second cause, and it is recorded against O-8 rather than
given a number of its own.

### 6. No ledger version bump

`LedgerFormat.version` stays 2. The version numbers the shape of records that already exist,
and none of them changes; a new tag is exactly what `RecordFault.unknownToken` exists for
(ADR-0004 §4), and a binary that meets `transportSessionLost` without knowing it refuses the
replay and names the token, which is the designed behaviour rather than a gap in it. A bump
would make that binary refuse at the header instead, naming a version rather than the event.

## What this costs

- **A replacement re-sends what the dead operation held.** §5. The invariant holds and the
  volume does not, and nothing here bounds the volume.
- **The operation being replaced is orphaned.** Nothing aborts it — no route aborts, and
  ADR-0006 §6 makes the abort an operator action — so it holds parts until the lifecycle
  rule reaches it. ADR-0005 O-8, second cause.
- **A budget that a forgetful authority hands back.** §3's reading is right about the dead
  operation and it means an upload cannot exhaust across replacements. O-18.
- **A dependency with no compiler behind it.** §4 is safe only while exhaustion is decided
  in `settle` alone. A reviewer is the mechanism, as ADR-0006 §2's grammar rule and
  ADR-0007 §6's two numbers already made one.

## The honesty boundary

Nothing here is evidence about S3 or about any deployed plane. The rows, the written form
and the mapping are checked by `swift test` against doubles and a virtual clock, and a green
suite says the machine behaves as this document says.

That a real authority answers a forgotten operation in a way the transport reads as
`.unknownSession` is not established by any of it. The plane today lets S3's error escape
unhandled; rendering it is a later commit's, and whether S3's error carries the name that
rendering reads is UNVERIFIED and belongs to the recorded run.

## Deliberately not decided

- **A budget for replacements.** Bounding how often an operation may be replaced is a new
  budget, and O-18 is where the need would be demonstrated.
- **Aborting the operation being replaced.** It would need an abort endpoint, a permission
  and a decision about who may abort whose upload — ADR-0006 §6 refused all three, and
  nothing here asks for them.
- **Telling anyone a replacement happened.** The screen derives from the log, so a
  replacement is visible there; a signal beyond that is an application's decision.

## Open questions

### O-18. An authority that forgets on a schedule is a loop nothing charges

Open, ask, lose, open, for ever. A loss is not a refusal and must not become one (ADR-0002),
so nothing charges the loop, and §3's scoping hands back a fresh budget each time it goes
round.

This is ADR-0005 O-9's shape with a new cause, and it gets O-9's answer: the driver must not
invent a stopping rule, because every rule it could invent is a conclusion, and §4 is only
safe because the mapping concludes nothing. What is missing is somewhere else for the
decision to live — a caller that gives up, or a budget for losses that Core would have to
own. Both are decisions, neither is the driver's, and nothing today needs either.

In practice each turn of the loop performs I/O against an authority that has just created
the operation it is being asked about, so the loop is a property of the specification rather
than an observed behaviour. A double that forgets every operation reaches it immediately,
which is why this phase's driver test forgets once and then behaves.

## Observed against a deployed plane

Nothing yet. `docs/deploy.md` says what is recorded here and how.
