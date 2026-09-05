# ADR-0007 — The transfer that outlives the process, and the stand-in it is measured against

- **Status:** accepted
- **Date:** 2026-09-02
- **Scope:** a fourth package library, `DunnageTransport`, whose `UploadTransport` speaks
  the control plane's four routes and PUTs parts over a background `URLSession`; an iOS app
  that owns that session; a stand-in authority at `cloud/standin/`; `PayloadRef` on the
  intent and ledger format 2; a CI job that kills a process on the simulator and reads what
  the next one derives; a device procedure whose results are written down and never claimed
  by CI. Nothing is deployed. No AWS account is touched.
- **Builds on:** ADR-0001 §3 and §4, the boundary this transport is the first real
  implementation of. ADR-0004 §5, the ledger this phase gives a second format. ADR-0005 §1,
  whose sentence on the transport's phase §1 below supersedes; §5, whose coincidence of
  "stopped waiting" and "stopped" §4 below ends; §7, the precedent §3 below follows.
  ADR-0006 §2, §3 and §4, whose four routes the stand-in serves and whose Swift half lands
  here.
- **Supersedes:** ADR-0005 §1's sentence *Where "a real transport" goes. To phase 4.* Its
  next sentence, that the lifecycle half is phase 5's, stands. ADR-0006 in four places,
  each in the one respect that a thing assigned to 4b lands here: §2's bullet
  `parseSession — Swift, 4b`; §3's paragraph "What 4a records, and what it does not
  decide"; the "Deliberately not decided" bullet on which `TransportError` a malformed
  identity throws; O-12's closing paragraph. Nothing else in either document changes.

## Context

The record precedes the code for the reason ADR-0006 §1 gave: the decisions here are kept,
or broken, in another language, another suite and another phase, and nothing a compiler
sees connects the halves. The stand-in's behaviour is an assumption about S3 that only 4b's
contract run can check (§9). The stall bound is one number in Swift and the same number in
TypeScript (§6). What CI's kill shows and does not show is a sentence that the test's name
cannot carry (§2). Each has to be written down somewhere both halves are read from, before
either half exists.

ADR-0005 §1 sent "a real transport" to phase 4 for three reasons that compounded: a
background configuration only does the thing it exists for inside an app, and there was
none; presigned URLs come from a control plane, and there was none; and localhost is not a
network. The app removes the first. 4a removed most of the second: the four routes exist as
code, and what is missing is a deployed instance of them, not their shape. The third stands
and is this phase's honesty line: **nothing here is evidence about a network.** What phase 5
can establish, and 4b cannot, is the lifecycle half — a transfer handed to the system
outlives the process that handed it over, and the next process resumes from the log alone.
That half needs a transport that leaves the process, which an in-memory double cannot be,
and it does not need S3. It needs an authority with S3 multipart's shape.

## Decision

### 1. The transport is phase 5's, spoken against a stand-in, and four riders

The background-`URLSession` transport moves to phase 5 and is spoken against a local
stand-in authority with S3 multipart's shape — a PUT per part, a list of the parts held, a
complete. 4b keeps the contract run of the same transport against the deployed plane and
S3. The sentence this replaces is ADR-0005 §1's *To phase 4*; the reasoning behind that
sentence is kept above, and its lifecycle sentence is untouched.

**One transport, not two.** 4b runs the same code against the real plane by changing its
base URL and its bearer token, and nothing else. The wire shapes are identical by
construction, because the stand-in serves the four routes ADR-0006 §4 wrote down, and
nothing else on its front half.

**O-12 moves here with the transport.** A background upload task reads a file, so
`PayloadRef` and the ledger format bump it forces cannot wait for 4b. §8.

**The stand-in is a double of this repository's contract, never of S3.** Its front half is
the four routes this repository declared and can therefore specify. ADR-0006 §4's rule — no
stubbed `S3Client`, because a double of a vendor's product runs a guess against itself — is
kept, not bent.

**The stand-in's data plane is a reading of S3's wire contract, confined to what the
transport reads.** Accepting a PUT on a URL it issued and answering a status and an ETag
header is not this repository's contract. UNVERIFIED: that S3 answers a presigned part PUT
with a 2xx status and an `ETag` header. It is assigned to 4b's contract run, with §9's other
two. The stand-in's PUT is written as narrowly as the transport's own reading of the
response — the status, §5 — and is named as a double of the plane, never as S3. The phase's
claims are about lifecycle and correlation; nothing here claims agreement with S3, and
"confirmed" means what the stand-in's own part store reports through `/parts`.

`parseSession`, the `TransportError` case for a session identity this transport never
minted, and `PayloadRef` travel with the transport.

### 2. Three tiers, and the naming rule

A test's tier is a property of the test — what it touches — and not of the runner that
happens to execute it.

| Tier | Touches | Shows |
|---|---|---|
| deterministic | `swift test`, or the app's unit-test bundle. Virtual clock, no session, no socket. | The transport's pure halves: the task description and its parse, `parseSession`, response decoding, the delegate's bookkeeping. The driver against a double whose transfer outlives the driver's wait. |
| simulator evidence | `xcodebuild test` on the CI image, against the stand-in on `127.0.0.1`. One named test launches the app, kills it mid-transfer, relaunches it, and reads the second process from outside. | Process B derives its state from a file process A left, shares no memory with A, and the second driver asks before it sends. |
| device harness | A numbered procedure on a real iPhone: background-then-kill, force-quit, airplane mode mid-transfer. | Observations, recorded under "Observed on a device" below and in the phase ledger. Never a CI claim; no CI step depends on it. |

The kill in tier 2 is real: the process on the simulator is gone. What it does not show:
suspension, jetsam, relaunch for events, force-quit, radio, power. Which signal the kill
delivers is UNVERIFIED until the phase observes it, and is O-14 below rather than a name.

**The naming rule.** Tier-1 names name the injected fault. Tier-2 names say the simulator
terminated the process. Tier 3 has steps, not tests. No name says SIGKILL, death, or device
unless it is tier 3, and tier 3 has no test names.

**The simulator job signs the app ad-hoc rather than building with signing off.** The 4a
spec's §4 said CI would build with `CODE_SIGNING_ALLOWED=NO`; it does not. What was observed
while the tier-2 test was written: under XCUITest the ad-hoc build runs its part tasks, and
the `CODE_SIGNING_ALLOWED=NO` build fails them at once with `NSCocoaErrorDomain 4097` and no
PUT leaves the process — which would leave the tier-2 test measuring nothing. The builds
differ as codesign-adhoc (`flags=0x2`) from linker-signed (`flags=0x20002`), and neither
carries an `application-identifier` entitlement, so that entitlement is not the difference
and no mechanism is asserted here. Which difference causes it is O-16. Ad-hoc signing needs
no Apple account, no provisioning profile and no team, so what CI claims about credentials
is unchanged: the guard that fails on a non-empty `DEVELOPMENT_TEAM` still runs.

Row 5 of `README.md` reads, from this commit:

> The bound survives the process: a transfer outlives the driver that started it, and a
> relaunched process resumes from the log alone and re-sends nothing the authority
> confirmed. CI's evidence is a real kill of a process on the simulator; suspension,
> jetsam and force-quit on a device are the harness's to record, never CI's.

### 3. An effect carries what its executor needs

After a cold start the driver replays the log and executes effects. `UploadEffect.send`
carries a list of `PlannedTransfer` and a `TransportSessionID`, and
`UploadTransport.send(_:in:)` receives a transfer and a session: a `ChunkID`, a `ByteRange`
and an opaque string. A transport that has to open a file cannot find the payload from
those. `confirmedProgress(in:)` receives the session alone, and a `Confirmation` carries an
`UploadID` the transport was never given; the in-memory double fills it from what it
remembers, which after a relaunch is nothing.

ADR-0005 §7 is the precedent: `openTransportSession` carried an identifier its executor
could not act on, and the effect gained the intent, because an effect that cannot be
executed from its own payload is not data a driver executes. The same rule, applied twice:

```
UploadEffect.send([PlannedTransfer], UploadIntent, TransportSessionID, after: Duration)
UploadTransport.send(_:of:in:)            the transfer, the intent, the session
UploadTransport.confirmedProgress(for:in:)  the upload, the session
```

The intent carries `PayloadRef` (§8), so `send` can locate the bytes. The
`askAuthorityForConfirmedProgress` effect already carries the `UploadID`; the call now
receives it, so `confirmedProgress` can name the upload its answer is about. Core still
never reads inside either. The change lands in the commit after this one, with `PayloadRef`.

### 4. The task description, and one task per (session, chunk)

Three facts the design rests on. A background session runs only upload and download tasks,
from files: the four control-plane calls go over a foreground session, and only the PUTs go
over the background one. Each planned transfer is materialised as a chunk file, because a
background upload task sends a whole file and a part is a span of the payload. And
`taskDescription` is the one string the system persists with a task across relaunch.

**The task description** is a JSON object with sorted keys, in the ledger's own style,
naming the upload, the composed session identity and the chunk ordinal:

```
{"chunk":3,"session":"<ref>/<uploadId>","upload":"<upload id>"}
```

JSON and not a joined string, because both the upload id and the composed session identity
may contain `/`, and a delimiter that either side may contain is a parse that is not total.
The encoder and decoder are pure and are tier 1.

**A task whose description this transport did not mint is cancelled and never read as
progress.** Missing fields, a chunk ordinal below one, a session identity that does not
parse: all three mean the same thing — not ours — and a task that is not ours is not
evidence about any upload.

**At most one task per (session, chunk).** On creation the transport asks the session for
its pending tasks and adopts each by its description. From then on a `send` looks for an
adopted or created task for `(session, chunk)`; if one is in flight it awaits that task's
completion and does not create another. Otherwise it materialises the chunk file, obtains a
URL for the part (§6), creates the upload task with the description above, and awaits it.

**A task is registered before it is started.** `PartTaskSession` separates creating a task
from starting it, as `URLSession` does — a task is made, then `resume()`d — and `send`
creates, registers, then starts. Started first, a task could be reported on while the
registry did not yet hold its id, and the completion would be dropped as not this
transport's: the send would wait for an answer that had been and gone, and every later send
for that chunk would adopt a dead entry. This constrains the session written in the next
commit: `URLSessionPartTasks.createTask` must not call `resume()`, and `start(_:)` is where
the resume goes.

The await is a continuation the delegate resumes. **The driver's timeout cancels the await,
never the task.** The task's lifetime is the daemon's, bounded by the session's resource
timeout (§6). A transfer therefore outlives the driver that started it, which is the
sentence row 5 makes and the reason ADR-0005 §5 said the coincidence of "stopped waiting"
and "stopped" was a property of the double and not of the design.

### 5. The delegate's mapping, and where an unclaimed completion goes

The delegate maps a task's completion to exactly one `TransferOutcome`:

```
no error, status 2xx         reportedComplete(chunk)
no error, any other status   refused(chunk)         an answer, and the answer was no
an error                     interrupted(chunk)     no answer arrived
```

The ETag header is not read. The device retains no ETag (ADR-0006 §4), and a header the
transport does not read is one the stand-in emits only because the wire it doubles does.

**A completion no `send` is awaiting** — one delivered after relaunch for a task the
previous process created — is held in memory, handed to the first `send` that asks for that
chunk, and otherwise never reaches the log. The log records answers a driver received; a
driver that never asked was never answered. Confirmed progress comes only from `/parts`,
whatever the delegate saw.

### 6. O-13 — the stall bound, with a number on it

"Cancels the await, never the task" creates a bound the way ADR-0005 O-9 did: an adopted
task the daemon keeps retrying holds the chunk until the resource timeout ends it, and every
later `send` for that chunk awaits the same task. The constant is named, given a reason,
and recorded here as this phase's O-10-shaped exposure with a number on it.

The number is a **ceiling**, not an exact match. A part's URL is good for 900 seconds from
its minting — `EXPIRES_IN_SECONDS` in `cloud/handlers/urls.ts` — and the resource timeout
runs from the task's creation. The real guarantee is the plane's, not the timeout's: a PUT
presented with an expired URL is refused, 403, which §5 maps to `refused`; the driver
records the refusal, asks the authority and re-plans; the next `send` mints afresh. That
path has a tier-1 test on the scripted wire. The timeout bounds the other case — a task the
daemon never gets to present at all. A transfer that is never presented inside the life of
its URL can only end in a refusal, so the daemon is given no longer than that life:
`partTransferLifetime`, 900 seconds, set as `timeoutIntervalForResource` on the background
configuration by the app.

**F2: URLs are minted at `send`.** The spec left open whether the transport sets the timeout
to a cached URL's remaining life or mints at `send` so the two lives coincide. Minting at
`send` is taken. Each `send` asks `/urls` and uses the URL for its part, so the task's
lifetime and the URL's begin together, and the transport needs no clock — there is no cache
whose age it would have to read. The cost is N signatures per send, since `/urls` signs
every part from 1 to N at once. A `parts` list on `/urls`, so a send signs one, is 4b's if
it ever matters.

**The coupling, stated here the way ADR-0006 §2 stated the grammar's.** The 900 in
`cloud/handlers/urls.ts` and the 900 in
`Sources/DunnageTransport/URLSessionPartTasks.swift` are one number in two languages, and
nothing a compiler sees connects them. Each site carries a comment naming the other. The
rule lives here, because a comment cannot be the thing a reviewer of the *other* file is
expected to have read: the timeout is a ceiling over the URL's life, and lowering the
plane's expiry without lowering the timeout turns the ceiling into a number that bounds
nothing.

### 7. Chunk files

A chunk file is deleted when `/parts` confirms the chunk, not when a completion reports
it, and the files that exist at once are bounded by the in-flight set. That sentence is
both the cache's lifecycle and its disk bound. A chunk file is written at `send`, from
`PayloadRef` and the plan's range; deleting any of them is always safe, because the next
`send` re-derives it. The payload copy itself is deleted when the upload reaches a terminal
phase.

### 8. `PayloadRef`, format 2 refusing 1, and `.unrecognisedSession`

`UploadIntent` gains `payload: PayloadRef`, opaque to Core the way `DestinationRef` is:
never parsed, never compared structurally, never a source of authority. Its raw value is a
path relative to Application Support, so it survives the container moving. The app is the
only thing that resolves it. This closes ADR-0006 O-12, and it closes the gap that O-12
found in a phase-1 claim: a cold start now finds the payload on the log.

`LedgerFormat.version` becomes 2, and `declared`'s payload gains `"payload"` inside
`"intent"`. **A version-1 header is refused under ADR-0004 §4 rather than migrated.** No
version-1 log exists outside the suite, so a reader that defaulted `PayloadRef` for one
would be a migration written for a file no one has, and the reader ADR-0004 said a second
version would need is not written for the same reason. The suite's fixtures move to
version 2, and one named test keeps a version-1 header refused with its version in the
error.

`InMemoryTransportDouble` continues to synthesise bytes and ignores the ref, which is the
behaviour O-12 said hid the gap; its doc comment says so.

**`TransportError.unrecognisedSession`**, a new case, not `.unknownSession`. "This
transport never minted this string" and "the authority has forgotten the operation" are
different facts that happen to strand the upload the same way. ADR-0006 §3 fixed what the
case must not be — not a `TransferOutcome`, not an interruption, never an abandonment — and
a thrown error satisfies all three under ADR-0005 §8. `TransportError` is not in the
transition table, so the case costs no totality row. `parseSession` throws it for exactly
the three inputs ADR-0006 §2 named, and its call site carries the comment that section
requires.

### 9. The stand-in's three assumptions

The stand-in is a double of this repository's four-route contract and never of S3. That is
ADR-0006 §4's rule, and the precedent is `InMemoryTransportDouble`: the double implements
the transport contract, not a vendor's product. Its front half is measured against the
plane's with one instrument — the same refusal fixtures are asked of the four handlers and
the four stand-in routes through one adapter, and the answers are asserted equal in one
diff, so a double that grew more lenient than the plane reds by name.

Three things the stand-in does are assumptions about S3 that nothing in phase 5 checks.
Each is UNVERIFIED here, each is 4b's contract run's, beside the four falsifiers ADR-0006
§4 already assigned there, and a green stand-in test says the stand-in behaves as assumed
and nothing about S3.

1. UNVERIFIED: that S3 refuses a presigned PUT used for another part, or after its expiry,
   with 403. The stand-in answers 403. 4b's contract run checks it, with ADR-0006 §4's
   fourth falsifier.
2. UNVERIFIED: that S3 answers `ListParts` for an `uploadId` not under the key with
   `NoSuchUpload`. The stand-in answers 404 for that request, as its own assumption. The
   plane today does not: `cloud/handlers/parts.ts` and `complete.ts` catch nothing from
   S3, so `NoSuchUpload` escapes the handler unhandled and the gateway answers whatever it
   answers for an unhandled error. What the plane should render, and what the transport
   reads as `.unknownSession`, is settled in 4b when the contract run shows S3's actual
   error shape — see "Deliberately not decided". ADR-0006 §4's first falsifier is the
   same run.
3. UNVERIFIED: that S3 answers a presigned part PUT with a 2xx status and an `ETag` header
   (§1's fourth rider). The stand-in answers 200 and a header the transport does not read.
   4b's contract run checks it.

A PUT for a part number already stored is accepted, and the earlier bytes are replaced.
That is the behaviour ADR-0001 wrote the invariant's weaker claim against, and it is the
reason the stand-in counts a re-send rather than refusing it: the counter is what keeps
§10's control honest.

### 10. The negative control

The control is `ForgetfulTransport`: `confirmedProgress` answered from the completions
this process saw, which after a relaunch is nothing, and never from `/parts`. Everything
else about it is the honest transport — the same sends, the same refusals, the same task
adoption. The failure it reintroduces is the thesis's own: the driver re-sends parts 1 and
2 that the authority holds, and the stand-in's counter reads 2 for each, whatever the
daemon did with part 3.

The other candidate — a session that forgets its tasks — is not the control, because it is
not deterministic across daemon behaviour: it shows a duplicate PUT only if the daemon kept
the killed app's task alive, and on a daemon that cancelled it, control and contract show
the same number.

The triple keeps the roles phases 2, 3 and 4a gave it. *Contract*: the forgetful transport
keeps the contract it is measured against, and only `confirmedProgress`'s source differs;
tier 1, on the scripted wire. *Control*: the re-send counters at 2 for parts 1 and 2 after
the kill and relaunch; tier 2. *Contrast*: after the same relaunch-shaped reset, the honest
transport answers `confirmedProgress` from `/parts`; tier 1.

The control lives in the app target only, under `#if DEBUG` behind a launch argument, never
in `DunnageTransport` — the same isolation as 4a's control under `test/`. It is never
"fixed".

## What this costs

- **A rule with no compiler behind it.** §6's two 900s are enforced by a comment at each of
  two sites in two languages. A reviewer is the mechanism, as ADR-0006 §2's grammar rule
  already made one.
- **A URL per send.** F2 costs N signatures each time a part is sent, to buy a transport
  with no clock and two lives that begin together.
- **The app runs one upload at a time.** The driver is single-upload (ADR-0005), so the app
  calls `resume` on each ledger upload in turn. That is a limit stated, not a concurrency
  design.
- **Two ways to be unable to move remain.** ADR-0006's unparseable identity, now
  `.unrecognisedSession`, and its expired operation both still end in an upload that is not
  failed and cannot proceed. O-10's recovery is not decided here.
- **A double stands where S3 will.** Every green in this phase that touches the stand-in's
  data plane is a statement about §9's three assumptions, not about S3.

## The honesty boundary

Nothing here is evidence about a network. ADR-0005 §1's third reason is kept whole: nothing
that makes a real transport hard is present at `127.0.0.1` — no loss, no NAT rebinding, no
radio state, no server that agrees with the protocol in most places.

A kill on the simulator is a kill of a process on the simulator and no more. It is not
suspension, not jetsam, not a relaunch for events, not a force-quit, and not a device. The
test's name says the simulator terminated the process and does not say which signal did
it, because that is O-14.

The device harness's findings are observations. They are written under "Observed on a
device" below, dated, and never promoted to a CI claim. Anything the procedure observes
that contradicts a sentence in this document is written next to that sentence as an
observation, and the sentence is not softened.

## Deliberately not decided

- **O-10's recovery.** It now has two demonstrated needs — ADR-0006 §7's expired operation
  and §8's `.unrecognisedSession` — and still one decision: what it means to open a second
  transport operation for an upload that already has one. Not here.
- **More than one upload in flight.** The app runs them one at a time.
- **A checkpoint.** State is still derived by replaying the whole file.
- **Jitter.** ADR-0005 left it out with one process; there is still one.
- **A per-chunk timeout.** One quiet timeout for the whole driver, and now one resource
  timeout for the whole session.
- **A `parts` list on `/urls`.** F2's cost is N signatures per send; the route that signs
  one is 4b's if the cost is ever demonstrated.
- **What the plane renders for `NoSuchUpload`, and what the transport reads as
  `.unknownSession`.** The stand-in's 404 is its own assumption (§9). The plane today lets
  S3's error escape unhandled, and the status a device sees for a forgotten operation is
  settled in 4b, when the contract run shows S3's actual error shape. Until then the
  transport's 404 reading is provisional and is written against the stand-in, and the
  commit that lands it says so.

## Open questions

### O-13. The stall bound

§6 above. Its open half — timeout from a cached URL's remaining life, or mint at `send` —
is settled by F2. What stays open: UNVERIFIED whether `timeoutIntervalForResource` on a
background configuration counts while the app is suspended. The number is right either
way; what it bounds differs, and the device harness's third step records what it sees.

### O-14. Which signal the kill delivers, and what the daemon does with a killed app's tasks

UNVERIFIED: which signal `XCUIApplication.terminate()` delivers to the process on the
simulator, and whether the simulator's daemon keeps or cancels a killed app's tasks — and
the same two questions on a device, where the harness's first two steps record them. The
`last-exit` marker the app writes on `applicationWillTerminate` is evidence only when
present; its absence is never read as SIGKILL, because a process killed before the hook
ran and a hook that never runs leave the same missing file.

### O-15. The security-scoped URL

The file the user picks is copied into the app's container, and `PayloadRef` names the
copy, never the picker's security-scoped URL. UNVERIFIED: whether the background daemon
can read a scoped URL after relaunch, or copies the file itself. This repository does not
rely on either answer; the harness's fourth step records what it sees.

### O-16. Why the unsigned build's part tasks fail

An app built with `CODE_SIGNING_ALLOWED=NO` fails every part task at once with
`NSCocoaErrorDomain 4097`; the same app signed ad-hoc for the simulator does not (§2). The
two builds differ as linker-signed from codesign-adhoc, and neither carries an
`application-identifier` entitlement, so the entitlement is not the difference. UNVERIFIED:
which difference is, and whether the failure reproduces on another machine — it was seen by
one party while the tier-2 test was written and has not been reproduced by a second. Nothing
in the phase rests on the answer: the job signs ad-hoc, which needs no account, profile or
team, and the claim about credentials is unchanged either way.

### O-17. A tier-1 wait that counts yields and not progress

**Decided by the commit "wait on the event a double publishes, and let the runner bound the
wait".** The paragraphs below record why it was left open, and what they name has since been
done: `settled(within:)` is gone from all four files that held a copy of it, the doubles
publish the events the tests were polling for — the scripted wire hands out its starts, the
transport counts the waiters it has stored — and a test awaits the event, its own `Task`, or
nothing at all. The reproduction below was run again there, under one load on one machine,
against both forms of the same tests: the polling form failed and the awaiting form passed.

`settled(within:)` — the helper the transport's tier-1 tests wait with — loops
`await Task.yield()` a fixed number of times and fails when the count runs out. The count is
not a measure of progress: under CPU starvation a poller can spend its whole budget before
the task it is waiting for is ever scheduled, so a test that is deterministic on an idle
machine is not deterministic on a busy one.

Observed: `TransportSendTests` at bound `10_000`, five failures in
`testASendMintsItsURLAtSendAndCreatesOneTaskNamedForTheChunk` with an `xcodebuild` build and
a simulator boot running beside it; 114 of 114 on every unloaded run, with the package
byte-identical to HEAD. It is not a regression in the code under test — it is the wait.

UNVERIFIED: whether this has ever fired in CI, where the Swift job runs alone on its own
runner, and therefore whether the exposure is the test's or the machine's.

Raising the bound is refused: "deterministic only" is not "deterministic if you wait long
enough", and a larger number makes a test slower to fail without making it more correct.
**The commit after this one closes it by removing the poll**: the double publishes the
event — a queue of starts the wire hands out, and the count of waiters the transport has
stored — and the test awaits that. No clock, no bound, no yield count; a genuine failure
then hangs. An `XCTWaiter` timeout is refused for the same reason as a larger bound: it is
a wall-clock wait wearing a different hat.

**CORRECTION, made by the same commit.** The sentence written here first said the hang runs
"until XCTest's own per-test timeout, which is the runner's backstop". That was asserted and
not checked, and it is wrong. Measured with a throwaway test holding a continuation nothing
resumes: `swift test` enforces no per-test timeout and names nothing — the test ran 300 s
until a probe killed it, printing nothing at all with output captured, which is how CI reads
it — and `xcrun xctest -test-timeouts-enabled YES` hung too, so the flag does not reach the
bare harness. The allowance is enforced by the runner `xcodebuild` drives, where it works,
fails at the allowance with the test named, exits 65, and rounds up to a whole minute.
Today's real backstop is the workflow's, and until that commit `ci.yml` set
`timeout-minutes` on none of its five jobs. It now sets 10 on **build and test** and 30 on
**app simulator**, and adds `-test-timeouts-enabled YES
-default-test-execution-time-allowance` to the app job's `xcodebuild test` step, which is
the one place a hang can be made to red naming the test rather than cancelling a job.

## Observed on a device

Nothing yet. `docs/device-harness.md` says what is recorded here and how.

## What this supersedes in the 4a design spec

`docs/superpowers/specs/2026-08-29-phase-4a-control-plane-design.md` is committed, it will
be read again, and nothing in it will say it was corrected. ADR-0006 §9 already owed it a
supersession list; this document owes it two more entries.

- **§12 lists `S3UploadTransport`, `PayloadRef` and the ledger format bump as out of
  scope for 4a and 4b's.** The transport is phase 5's under §1 above, and is not named
  `S3UploadTransport`, because what it speaks is the plane's four routes and not S3;
  `PayloadRef` and format 2 are phase 5's under §8. The bucket, presigned URLs against a
  real service, the recorded contract run and O-10's recovery stay 4b's, as §12 has them.
- **Its "Leaves to 4b" bullet, in the same respect.** `S3UploadTransport` and "the
  `PayloadRef` change to Core" land here. The rest of the bullet stands.

Nothing else in that spec is touched.
