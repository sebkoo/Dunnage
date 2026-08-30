# ADR-0005 — The driver, and the clock it waits behind

- **Status:** accepted
- **Date:** 2026-08-29
- **Scope:** a new `DunnageDriver` module. No real transport, no background `URLSession`,
  no app, no AWS.
- **Builds on:** ADR-0002 and ADR-0003, which specified this driver before any of it
  existed. ADR-0001's "no clock" note is amended here, and §4 says exactly how.

## Context

Three documents already say what the driver does, written when there was nothing to
execute them:

```
ADR-0002 §what      maps TransferOutcome to events one-for-one. Never a refusal
                    synthesised from an interruption, never either turned into abandoned.
ADR-0002 §what      a timeout is driver policy. Core does not measure how long a transfer
                    was quiet.
ADR-0003 §2, §5     the tally is derived from the log. abandon is Core's conclusion, and
                    the driver does not reach one of its own.
ADR-0003 §4         `after` is honoured before the transfer. It is the only place backoff
                    exists.
```

So this phase is not a design exercise. It is a test of whether that specification was
writable, and §7 and §8 below record the two places it was not.

The driver executes and records. There are three ways it concludes by accident, and each
is a real failure:

- it decides a slow transfer is a refusal, so a flaky network spends a retry budget on
  chunks that were never in trouble and the upload gives up while the authority was
  holding most of it;
- it counts attempts itself, so there are two tallies and a rule for what to do when they
  disagree;
- it decides to give up, so `.failed` is reached by something other than Core's own
  decision and the terminal state stops meaning what ADR-0003 §5 says.

## Decision

### 1. This phase is the driver alone, and `README.md` row 3 says so

Row 3 claimed the bound holds *against a real transport*. A scripted double is not one, so
the row and the phase had to be reconciled. Two ways to do that were on the table.

**(b) Build a `URLSession`-backed transport too, tested against a server on localhost.**
Rejected, for three reasons that compound.

The transport this library needs owns a **background** `URLSession` and speaks S3 multipart
against presigned URLs. A background configuration only does the thing it exists for inside
an app, and there is no app; presigned URLs come from a control plane, and there is none.
What could be built today is a foreground session speaking a protocol invented for its own
test — a transport with no consumer, which is the speculative abstraction the architecture
rules out.

And a local server is not a network. Nothing that makes a real transport hard is present at
`127.0.0.1`: no loss, no NAT rebinding, no radio state, no system suspending the app
mid-transfer, no server that agrees with the protocol in most places. Row 3 would then be
entitled to say "a real transport" while the phase had established nothing whatsoever about
the world.

**(a) The driver alone, against the double that already exists, and row 3 reworded.**
Chosen. The driver's contract is the falsifiable part, it is already written down in two
ADRs, and none of it has ever been executed. "A real transport" is a claim about the world,
and it moves to the phase where the authority that makes it meaningful first exists.

**What that costs, stated rather than implied.** This phase establishes nothing about the
world. Every test in it is a scripted double and a virtual clock, and no byte leaves the
process. It proves that the driver keeps the contract three ADRs wrote for it, and that is
all it proves.

**Where "a real transport" goes.** To phase 4. An S3-speaking transport cannot exist before
the control plane that issues its URLs, so the transport and the plane it talks to are one
phase, not two. The lifecycle half — that the invariant survives a background session and
real process death — stays phase 5's, where the device harness is.

### 2. The driver is a loop over effects, and it holds no state of its own

```
replay the log ─▶ outstanding work ─▶ execute one effect ─▶ append what happened
      ▲                                                              │
      └──────────────── fold, and queue what the fold asked for ◀─────┘
```

`UploadDriver` is a `struct` holding three injected collaborators — a transport, a log and
a clock — and one number, the timeout in §5. It has no counters, no cache and no notion of
where an upload got to. That
is not an economy; it is ADR-0003 §2 in the type system. A driver with a field is a driver
with a second answer to a question the log already answers, and then a rule for what to do
when the two disagree.

The queue holds **distinct** effects. Five transfers in one round produce five events, each
of which folds to the same `askAuthorityForConfirmedProgress`, and two identical questions
are one question. Without that, the second answer would produce a second `send` for chunks
the first had already put in flight — one round, two transfers per chunk, and ADR-0003 §1's
"at most one charge per answer" quietly over-charging.

### 3. An answer becomes one event, and it is on the log before the next transfer begins

The mapping is total and adds nothing:

```
TransferOutcome.reportedComplete(c)  ─▶  UploadEvent.chunkTransferReported(c)
TransferOutcome.refused(c)           ─▶  UploadEvent.chunkTransferRefused(c)
TransferOutcome.interrupted(c)       ─▶  UploadEvent.chunkTransferInterrupted(c)
```

The ordering is load-bearing and is not merely tidiness. `Attempts` is derived from the
log (ADR-0003 §2), so a refusal that is still in memory when the process goes away is an
attempt that never happened. A driver that collected a round's answers and appended them
together would lose a whole round's tally to one process death — and an upload that dies on
every attempt would retry for ever, which is the exact failure a retry budget exists to
stop.

Rejected events are appended too. The log records what happened, including events the
machine had no rule for in the phase they arrived in; `UploadTransition.replay` is already
explicit about folding those to no change.

### 4. The clock is the driver's, declared in the driver's module

ADR-0001 recorded "no clock", on the grounds that no invariant in scope depended on time.
Two now do — the backoff `after` on a send effect, and the timeout in §5 — and both are the
driver's. So:

```swift
public protocol DriverClock: Sendable {
    func wait(for duration: Duration) async throws
}
```

It is declared in `DunnageDriver`, not in Core. **Core gains nothing and its purity note
stands unchanged, literally rather than by interpretation:** Core still reads no clock,
runs no timer and sleeps not at all, and `Duration` on a `send` effect is still a value
computed from a policy rather than a reading of the present time.

One method, because the driver has one need: to not proceed for a while. A `now` would let
the driver compute a duration of its own, and every duration the driver is allowed to
compute is a number Core did not sanction.

The suite's conformance grants a wait only when a test says it may, and has no timeline at
all: every ordering the suite asserts is between actions — a wait taken before a transfer
began — and not between instants, so no test is slower because a backoff is long. The
package's other conformance sleeps, is used by nothing in the suite, and is the one piece
of production code here with no test behind it: a test of a real sleep is a wall-clock wait,
which this repository does not have.

### 5. A transfer that never answers is quiet, and quiet is an interruption

The driver arms its own timeout for each transfer and, when the timeout wins, records
`chunkTransferInterrupted`. Nothing about the duration reaches the log, so a transfer the
transport called interrupted and a transfer the driver stopped waiting for are the same
event, and Core cannot tell them apart — which is the point. There is no third event and no
new `TransferOutcome` case, because "no answer arrived" is exactly what the existing one
means.

Two things this deliberately does not say.

**It does not say the transfer failed.** `chunkTransferInterrupted` is the absence of an
answer, not a claim about the bytes. Core's response to it is to ask the authority, and if
the bytes did land, the next answer says so and the chunk is never sent again. The driver's
timeout is therefore safe *because* of ADR-0002: it is a decision about how long to wait,
not a decision about a chunk.

**It does not say the transfer stopped.** In this phase the driver stops waiting and the
double's transfer stops with it, because the double is in-process. A background
`URLSession` transfer would not stop, and the event would still be true, because the event
is about the answer and not about the transfer. That the two coincide here is a property of
the double and not a property of the design.

The timeout is never charged. It produces the event that ADR-0003 §1 says costs nothing,
and a driver that spends a budget on its own impatience has re-created the collapse
ADR-0002 removed, on the other side of the boundary.

### 6. A cold start asks

`UploadTransition.replay` discards effects on purpose — re-emitting them would re-send
bytes on every cold start — so a driver picking an upload up from the log has a state and
no work. It needs a rule, and the rule is the weakest effect each phase already produces
on entry:

```
.undeclared     nothing. The log knows no such upload.
.declared       open a transport operation
.transferring   ask the authority
.finalizing     ask for the object to be created
terminal        nothing
```

`send` is not on that list and cannot be. A resumed upload asks before it sends, so nothing
goes out against an answer given before the process died.

### 7. Where the specification was not writable: `openTransportSession` could not be executed

`UploadEffect.openTransportSession(UploadID)` carried an identifier, and
`UploadTransport.openSession(for:)` takes an intent. A driver holding only the effect
cannot perform it; it has to reach back into the state it just folded and pull the intent
out — which puts the driver in the business of deciding what an effect meant.

The effect now carries the intent. Effects are data a driver executes, and one that cannot
be executed from its own payload is not that. This is the first change to Core that a
consumer forced, which is what a first consumer is for.

### 8. A thrown error becomes no event, and the driver stops

`UploadTransport`'s methods are `throws`, and a thrown error is not a `TransferOutcome`.
No ADR said what one becomes, and the honest answer is: nothing.

There is no event in the alphabet for "the request could not be made", and inventing a
mapping would be the synthesis ADR-0002 forbids — `TransportError.unknownSession` is an
answer about the *operation*, not an answer about a chunk, and calling it an interruption
would be a claim the transport never made. So the driver appends nothing, stops the round,
and lets the error out to its caller. The log is unchanged, which means a later run replays
to exactly the state the failed one started from and asks again.

A `send` that throws also stops the transfers queued behind it in the same round. Doing
less work is always safe here: the plan is re-derived from the authority's next answer, so
a transfer not attempted is a transfer the next round attempts.

## The honesty boundary

No test in this phase touches a network, a real clock, or a real transport. Every wait is
virtual, every answer is scripted, and the only failure injected is one the suite wrote.

In particular, **a scripted silence is not a stalled TCP connection.** What the suite
establishes is that *given* a transfer that does not answer within the driver's timeout,
the driver records an interruption, charges nothing, and asks the authority. Whether a real
network produces that shape of silence, and whether a background session's transfer would
still be running afterwards, is not established here and is phase 4's and phase 5's to
establish.

The driver is also single-upload and in-process. Nothing here says anything about many
uploads at once, about the system relaunching an app to deliver an event, or about a
transfer that outlives the process that started it.

## Deliberately not decided

- **No jitter.** ADR-0003 §4 left jitter to the driver, "at the boundary where randomness
  is allowed to live". The driver has no randomness source and none is introduced: a
  thundering herd needs many devices, and there is one process. Adding entropy now would
  fix an injection boundary against a problem nothing has demonstrated.
- **No concurrency within a round.** Transfers in one `send` effect go one at a time.
  Doing them at once is a throughput decision, it changes nothing about the invariants
  here, and it would make the durability ordering in §3 much harder to state.
- **No per-chunk timeout.** One quiet timeout for the whole driver. A transfer whose size
  makes that number wrong is a real problem and there is no real transport to demonstrate
  it against.

## Open questions

### O-8. A transport operation opened and never recorded is orphaned

The driver opens a session and then appends `transportSessionOpened`. If the process dies
between the two, the operation exists at the authority and nothing on the log names it. The
next run replays to `.declared`, opens a second one, and the first is never completed or
aborted.

It costs storage at the authority, not correctness: the orphan holds parts nobody will
complete, and the thesis is untouched, because no confirmed chunk is re-sent — the second
operation simply has nothing confirmed in it. Closing it means writing an intent to open
before opening, which is a new event, a new row in the transition table, and a decision
about what a recorded intent with no session means. Not today.

### O-9. An upload that is only ever interrupted never terminates

An interruption costs nothing (ADR-0002 §3, ADR-0003 §1), so a transport that answers
nothing, for ever, produces a driver that asks, sends, times out and asks again, for ever.

This is not an oversight in the driver; it is the specification working. The driver must
not invent a stopping rule, because every stopping rule it could invent is a conclusion,
and §5 above is only safe because the timeout concludes nothing. What is missing is
somewhere else for the decision to live: a caller that gives up, a budget for interruptions
that Core would have to own, or a connectivity signal that says waiting is pointless. All
three are decisions, none of them is the driver's, and none is needed by anything today.

### O-10. An authority that has forgotten the operation leaves the upload stuck

`confirmedProgress` throws `TransportError.unknownSession` when the multipart upload has
been aborted or has expired. Under §8 the driver appends nothing and stops, so every later
run asks, throws and stops again. The upload is not failed — it is unable to move.

Recovering means opening a second transport operation for an upload that already has one,
and ADR-0001 §2 already refused to decide that: the transition table rejects it with
`transportSessionAlreadyOpen`, and replacing an operation is a separate decision. It is now
a decision with a demonstrated need, which is the condition ADR-0001 set for making it.

### O-11. Nothing appends `abandoned(.taskCancelled)`

`FailureReason.taskCancelled` exists and no code path reaches it. Cancelling is an
application's decision, not a driver's conclusion, so the driver honouring task cancellation
by stopping — which it does, since every wait it takes is cancellable — is not the same act
and does not write to the log. Which object turns a user's "cancel this" into an
`abandoned` event, and whether Core should produce an effect for it, is not decided, because
there is no application yet to ask.
