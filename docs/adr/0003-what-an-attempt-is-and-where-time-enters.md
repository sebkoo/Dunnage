# ADR-0003 — What an attempt is, and where time enters

- **Status:** accepted
- **Date:** 2026-08-29
- **Scope:** `DunnageCore` only. No driver, no transport implementation, no disk.
- **Builds on:** ADR-0001 (what "confirmed" means) and ADR-0002 (an interruption is not a
  failure), which fixed the rule this document has to keep: an interruption is not an
  attempt.

## Context

`.failed` is terminal and absorbing. An upload that reaches it never leaves, so reaching it
had better be a decision — traceable to a rule that was written down before the first byte
moved — and not a state the fold slid into because a counter happened to run out.

Three questions have to be answered together to say that:

1. What spends a retry budget. ADR-0002 fixed half the answer by ruling out interruptions;
   it deferred the other half because there was no policy to state it against.
2. Where the count lives, given that the append-only log is the only source of truth.
3. Where time enters, given that backoff is a wait and Core is pure.

## Decision

### 1. An attempt is a refusal, charged at most once per answer from the authority

A refusal is the transport answering no about one transfer. That is the only observation
that spends budget. A completion report spends nothing (it is good news, and unverified good
news at that), and an interruption spends nothing (ADR-0002: no answer arrived, so nothing
was learned).

Two identical `chunkTransferRefused` events on the log are ambiguous: one refusal delivered
twice, or two refusals of two successive retries. The log cannot tell them apart, and it is
not allowed to drop either. So the rule is stated so that it does not have to:

> A chunk is charged at most once between one answer from the authority and the next.

This is sound because of a property of the transition table: **`.send` is produced only by
settling a confirmation.** Every other event produces at most a question for the authority.
So Core hands a given chunk to a transport exactly once per answer, at most one genuine
refusal per chunk can follow, and a second identical refusal in the same window is a
repeated delivery.

**This makes the property a load-bearing one.** A later change that emits `.send` from any
other event breaks the rule, and the tally silently starts over-charging. If that change is
ever wanted, this ADR is what has to be revisited.

### 2. The tally is derived from the log, not held by the driver

`Attempts` is part of the machine state, which is a pure fold over the log. A driver keeping
the count in memory would lose it on every cold start, and an upload that crashes the process
on each attempt would then retry for ever — the exact shape of failure a retry budget exists
to stop.

### 3. The policy lives on `UploadIntent`

`UploadIntent` is what `declared` carries, so the policy reaches the log with the
declaration and comes back with it. A policy handed to the fold alongside the log would be a
second input to a function that is supposed to have one, and replaying the same log under a
different policy would derive a different upload.

### 4. Time enters as data on an effect. Core still has no clock

```swift
case send([PlannedTransfer], TransportSessionID, after: Duration)
```

Core computes how long the next attempt should wait — from the policy and the attempts
already spent — and hands that back as data. **The driver is the thing that waits, behind
its own injected clock.** Nothing in Core reads a clock, sleeps, or runs a timer, and no
clock protocol is introduced: ADR-0001's "no clock" note stands unchanged, because a value
computed from a policy is not a reading of the present time.

Two consequences worth stating:

- **No jitter.** Backoff is deterministic doubling to a cap. Jitter needs entropy, and Core
  has none by construction. Spreading a thundering herd is a driver's problem, at the
  boundary where randomness is allowed to live.
- **A stall is still the absence of an answer.** Nothing in Core measures how long a
  transfer has been quiet. Deciding that a quiet transfer should now be called interrupted
  is a driver policy, and it needs the driver's clock, not Core's.

Backoff is earned by refusals only. An interruption earns no wait, because nothing answered
no and there is nothing to back away from. Waiting for connectivity to come back is a
different thing from backing off an endpoint, it belongs to the driver, and conflating them
here would put a network condition into the retry budget by the back door.

### 5. Exhaustion produces an effect asking to give up; `.abandoned` is what gives up

When the authority answers and some chunk that is still outstanding has spent its budget,
the effect is `abandon(upload, .retriesExhausted)`. Core does not enter `.failed` itself.
`.abandoned` remains the only event that reaches a terminal phase, so the entry is a line on
the log rather than a conclusion the fold reached on its own.

The decision is taken **against a fresh answer from the authority**, not at the moment of the
refusal. That ordering is deliberate and it buys two things: a chunk that spent its last
attempt and then landed anyway is not outstanding at all, so the upload simply carries on;
and the confirmed set recorded next to the failure is the last thing the authority actually
said.

### 6. A failed upload keeps what was confirmed

```swift
case failed(intent: UploadIntent, reason: FailureReason, confirmed: ConfirmedProgress?)
```

Giving up is not a reason to forget. The confirmed set is the whole difference between an
upload that could be picked up later and one that would start from zero, and throwing it
away at the moment of failure would undo the thesis for precisely the uploads that needed it
most. It is `nil` only when the upload was abandoned before the authority had ever been
asked.

## What this constrains later

- **The driver (phase 3)** performs one transfer per chunk per `send` effect. Retrying a
  chunk on its own initiative, inside one round, hides attempts from the tally and from the
  log.
- **The driver does not count.** It appends observations and executes effects. The count is
  derived, and `abandon` is Core's, not the driver's own conclusion.
- **The driver waits.** `after` is a duration to honour before the transfer, behind whatever
  clock the driver injects. Honouring it is not optional: it is the only place backoff
  happens.

## Open questions

### O-4. Can a failed upload be resumed, and as what?

`.failed` is absorbing, and `.failed` now carries the confirmed set — which makes the
question askable for the first time. Resuming would mean either a new upload identity that
starts from that set, or a corrective event that reopens this one. Terminal states being
absorbing is load-bearing for replay, so reopening is not a small change.

Not decided. Nothing today needs it, and picking an answer now would fix a recovery model
against a driver that does not exist.

### O-5. Should a refusal say why?

`TransferOutcome.refused` carries no reason (ADR-0002 deferred it), so every refusal costs
the same. An expired presigned URL and a rejected payload are not equally worth retrying,
and a driver may well want the first to renew a URL rather than spend an attempt.

Not decided, for the same reason: the consumer does not exist yet.
