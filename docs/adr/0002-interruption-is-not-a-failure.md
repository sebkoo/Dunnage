# ADR-0002 — An interruption is not a failure

- **Status:** accepted
- **Date:** 2026-08-29
- **Scope:** `DunnageCore` only. No transport implementation and no driver exist yet.
- **Builds on:** ADR-0001, which fixed what "confirmed" means and why Core asks the
  authority rather than inferring progress from bytes it handed over.

## Context

ADR-0001 separated three mechanisms that are routinely collapsed — background execution,
the IETF resumable upload protocol, and S3 multipart — and made the shape of a confirmation
a sum type so that Core could not quietly translate one contract into another.

The same collapse happens one level down, among the ways a transfer can go wrong. Three
outcomes get written as one:

```
interrupted   The answer never arrived. The connection dropped, or the transfer stalled.
              Whether the bytes reached the authority is not known, and cannot be known
              from here.

refused       The answer arrived and it was no. This transfer did not become a unit the
              authority holds, and the transport is in a position to say so.

abandoned     The upload was given up on. A decision about the upload as a whole, not an
              observation about one chunk.
```

The previous shape of the boundary collapsed the first two into `TransferOutcome.failed`
and `TransferOutcome.stalled`, and it collapsed the first into the third by offering
`FailureReason.networkInterrupted` as a reason for abandoning an upload.

That collapse has a cost, and it is the same cost every time: **a retry budget spent on
chunks that were never in trouble.** If a dropped connection increments whatever counter a
refusal increments, a flaky network exhausts the budget of chunks whose transfer may well
have landed. The bound the thesis claims — redundant transfer limited to the unconfirmed
in-flight set — is not the thing that breaks; what breaks is that the upload gives up while
the authority was holding most of it.

## Decision

### 1. A transport's answer has three cases, and two of them are negative

```swift
public enum TransferOutcome: Hashable, Sendable {
    case reportedComplete(ChunkID)   // an answer, positive
    case refused(ChunkID)            // an answer, negative
    case interrupted(ChunkID)        // no answer at all
}
```

A dropped connection and a stall are one case, not two. Both say the same thing — nothing —
and a caller that could tell them apart would be reading a claim that was never made.

Neither negative case carries a `FailureReason`. A refusal is about one transfer; the
reasons an *upload* is given up on are a different question with different recovery paths,
and sharing one enum between them was what made `failed(.networkInterrupted)` expressible.

**Deliberately not decided:** `refused` carries no reason of its own. Distinguishing an
expired presigned URL from a rejected payload changes what a driver should do next, and
there is no driver yet. Adding the distinction now would fix a taxonomy against an
unwritten consumer.

### 2. Both observations reach the log, and neither is a confirmation

```swift
case chunkTransferRefused(ChunkID)
case chunkTransferInterrupted(ChunkID)
```

They join `chunkTransferReported` as observations. All three leave confirmed progress
exactly where it was and all three produce one effect: ask the authority. ADR-0001 §3
already forbids Core from inferring progress from bytes it handed to a transport; this
extends the same rule to the negative direction. **Core does not infer the absence of
progress either.** A refusal is the transport's account of its own request, not the
authority's account of what it holds.

`chunkTransferInterrupted` is the weakest statement in the alphabet, and it is on the log
because it happened. It is what sends Core to the authority after a connection drops.

### 3. An interruption is not a reason to abandon an upload

`FailureReason.networkInterrupted` is removed. Every remaining case — `taskCancelled`,
`systemTerminated`, `userForceQuit` — is a statement about the upload as a whole. A dropped
connection is not; it is the absence of an answer about one chunk.

Repeated interruption may eventually lead somewhere terminal, but the reason recorded there
is the decision that was taken, not the weather that prompted it.

UNVERIFIED: the background semantics of `userForceQuit` as against `systemTerminated`. They
are different reasons here, and which of them lets a transfer continue is not observable in
any suite this repository runs — ADR-0007 §2's third tier is where it is recorded, on a
device, by a written procedure.

## What this buys, and what it does not

Core still cannot tell whether an interrupted chunk landed. That is not a gap to be closed
later — it is the transport contract. The interruption itself carries no claim, the
authority is asked, and the resume plan follows the answer. Under a set-shaped authority
that kept the unit, the chunk is not sent again; under one that did not, it is. The
difference is the authority's, and Core's behaviour either side of the interruption is
identical.

This is the weaker-claim rule of ADR-0001 applied to the negative direction: where the
transport cannot make the stronger statement, the invariant is written against the weaker
one.

## What this constrains later

- **The driver (phase 3)** maps `TransferOutcome` to events one-for-one. It may not
  synthesise a refusal out of an interruption, or the reverse, and it may not turn either
  into `abandoned`. A driver that treats a timeout as a refusal has re-created the collapse
  this ADR removes, on the other side of the boundary.
- **A timeout is a driver policy, not a Core event.** An interruption is the absence of an
  answer, not a slow one, so nothing in Core waits for one or measures how long it waited.
  Deciding that a transfer has been quiet long enough to be called interrupted belongs to
  the driver.
- **What counts as an attempt** is left to ADR-0003, which needs a retry policy to state
  it against. The rule it will have to keep is fixed here: an interruption is not one.
