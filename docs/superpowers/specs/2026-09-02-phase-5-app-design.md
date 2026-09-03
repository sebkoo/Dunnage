# Phase 5 — the app, and the transfer that outlives the process that started it

- **Status:** design, approved for planning
- **Date:** 2026-09-02
- **Scope:** a fourth package library, `DunnageTransport`, whose `UploadTransport` speaks
  the control plane's four routes and PUTs parts over a background `URLSession`; an iOS
  app at `App/` that owns that session; a stand-in authority at `cloud/standin/`;
  `PayloadRef` on the intent and ledger format 2; a fifth CI job that kills a simulated
  process and reads what the next one derives; a device procedure whose results are
  written down and never claimed by CI. ADR-0007.
- **Leaves to 4b:** the bucket, the deployed plane, a Cognito token in the app, the recorded
  contract run of the same transport against S3, and the recovery ADR-0005 O-10 needs.
- **Supersedes:** ADR-0005 §1's sentence on where a real transport goes; ADR-0006 §2, §3,
  its "Deliberately not decided" bullet on the `TransportError` case, and O-12, each in
  the one respect that a thing they assigned to 4b now lands here; the 4a spec's §12 in
  the same respect. ADR-0007 names each. Nothing else in those documents changes.

Every decision below marked **[stated]** is the author's answer in the brainstorm that
produced this document, recorded as given. Everything else is the design that follows
from those answers, and the plan may not weaken a stated one.

## Why phase 5 comes before 4b

ADR-0005 §1 sent "a real transport" to phase 4 and gave three reasons a `URLSession`
transport against localhost could not be built in phase 3: a background configuration
only does the thing it exists for inside an app, and there was none; presigned URLs come
from a control plane, and there was none; and localhost is not a network.

Phase 5 removes the first reason and 4a removed most of the second. The third stands, and
it is the honesty line of this phase: **nothing here is evidence about a network.** What
phase 5 can establish, and 4b cannot, is the lifecycle half — a transfer handed to the
system outlives the process that handed it over, and the next process resumes from the
log alone. That half needs a transport that leaves the process, which an in-memory double
cannot be, and it does not need S3: it needs an authority with S3 multipart's shape.

**[stated] Decision 1.** The background-`URLSession` transport moves to phase 5 and is
spoken against a local stand-in authority with S3 multipart's shape — `UploadPart` to an
ETag, `ListParts`, `Complete`. 4b keeps the contract run against the real control plane
and S3. Four riders:

1. **One transport, not two.** 4b runs the same code against the real plane by changing
   its base URL and its bearer token, and nothing else. The wire shapes are identical by
   construction, because the stand-in serves the routes ADR-0006 §4 wrote down.
2. **O-12 moves here with the transport.** A background upload task reads a file, so
   `PayloadRef` and the ledger format bump it forces cannot wait for 4b. §6.
3. **The stand-in is a double of this repository's contract, never of S3.** Its front half
   is the four routes this repository declared and can therefore specify. ADR-0006 §4's
   rule — no stubbed `S3Client`, because a double of a vendor's product runs a guess
   against itself — is kept, not bent.
4. **The stand-in's data plane is a reading of S3's wire contract, and is confined to what
   the transport reads.** Accepting a PUT on a URL it issued and answering a status and an
   ETag header is not this repository's contract. It is written as narrowly as the
   transport's own reading of the response — the status — and named as a double of the
   plane, never as S3. ADR-0007 records it as an UNVERIFIED assumption that 4b's contract
   run settles. The phase's claims are about lifecycle and correlation; nothing here
   claims agreement with S3, and "confirmed" means what the stand-in's own part store
   reports through `/parts`.

`parseSession`, the `TransportError` case for a session identity this transport never
minted, and `PayloadRef` all travel with the transport. Rows 4b and 5 of `README.md` are
reworded in this phase's first commit, alongside ADR-0007 (§10).

## 1. What the phase claims, and the three tiers

**[stated] Decision 2.** Three tiers, by name, and a test's tier is a property of the test
— what it touches — and not of the runner that happens to execute it.

```
deterministic      swift test, or the app's unit-test bundle. Virtual clock, no session,
                   no socket. The transport's pure halves: the task description and its
                   parse, parseSession, response decoding, the delegate's bookkeeping.
                   The driver against a double whose transfer outlives the driver's wait.

simulator          xcodebuild test on macos-26 with Xcode 26.6, against the stand-in on
evidence           127.0.0.1. One named test launches the app, kills it mid-transfer,
                   relaunches it, and reads the second process from outside. The kill is
                   real: the process on the simulator is gone. What it shows: process B
                   derives its state from a file process A left, shares no memory with A,
                   and the second driver asks before it sends. What it does not show:
                   suspension, jetsam, relaunch for events, force-quit, radio, power.
                   Which signal the kill delivers is UNVERIFIED until the phase observes
                   it, and the spec says so rather than naming one.

device harness     A numbered procedure on a real iPhone: background-then-kill, force-quit,
                   airplane mode mid-transfer. Outcomes are recorded in the phase ledger
                   and in ADR-0007. It is never a CI claim, and no CI step depends on it.
```

**The naming rule.** Tier-1 names name the injected fault. Tier-2 names say the simulator
terminated the process. Tier 3 has steps, not tests. No name says SIGKILL, death, or device
unless it is tier 3, and tier 3 has no test names.

**Row 5 of `README.md`, verbatim:**

> The bound survives the process: a transfer outlives the driver that started it, and a
> relaunched process resumes from the log alone and re-sends nothing the authority
> confirmed. CI's evidence is a real kill of a process on the simulator; suspension,
> jetsam and force-quit on a device are the harness's to record, never CI's.

### 1.1 How the simulator tier kills, and how it observes

**[stated] Decision 2b.** A UI-test target. One named XCTest launches the app with the
stand-in's port as a launch argument, drives the pick, tells the stand-in to hold part 3,
calls `XCUIApplication.terminate()` while that PUT is unanswered, releases the hold,
relaunches, and asserts from outside the app: the stand-in's counter says part 3 was PUT
once, and the app's screen, read through accessibility labels, shows part 3 confirmed.
One `xcodebuild test` invocation, one test name the name guard can record. Rider:

- **The kill is sequenced on the stand-in's report, not on time.** The test polls
  `/_standin/` with a bounded count until it reports *part 3 received, held*, then
  terminates, then releases, then relaunches. No sleep and no progress estimate anywhere
  in the sequence; every wait inside the test is finite and named.
- **The second assertion is evidence only because of a precondition the spec states:** the
  relaunched app derives what it shows by replaying the ledger, and nothing else. §4.3.
- The signal `terminate()` delivers stays UNVERIFIED.

The shell alternative — `simctl launch`, `simctl terminate`, read the ledger out of the
container with `simctl get_app_container` and replay it with a tool — was considered and
not taken: it needs a replay tool the package does not have, and its evidence is a script
the name guard cannot see.

## 2. Layout

```
Package.swift                 gains DunnageTransport; DunnageTests covers its pure halves
Sources/DunnageTransport/
  BackgroundSessionTransport.swift   UploadTransport over a URLSession it did not configure
  TaskDescription.swift              the string the system persists with a task; its parse
  SessionIdentity.swift              parseSession — the Swift half of ADR-0006 §2
  ControlPlane.swift                 the four routes' request and response shapes
  ChunkFiles.swift                   the chunk-file cache, and its bound
App/
  Dunnage.xcodeproj             committed. Synchronized folders, so adding a file is not a
                                pbxproj change. References the package at `..`
  Dunnage/                      the app target
    DunnageApp.swift            session identifier and configuration, the delegate hookup,
                                the handleEventsForBackgroundURLSession completion handler
    UploadScreen.swift          pick a file, watch chunks confirm
    Container.swift             the ledger directory, the payload copy, the chunk directory
    NegativeControl/            ForgetfulTransport, #if DEBUG, behind a launch argument
  DunnageTests/                 tier 1 on the simulator: no session, scripted wire
  DunnageUITests/               tier 2: kill-and-relaunch, and the control's counter
  Shared.xcconfig               committed; team empty; #include? "Local.xcconfig"
  Local.xcconfig                gitignored; an operator's team, for the device procedure
cloud/standin/
  server.ts                     the four routes, the PUT, and the /_standin/ controls
cloud/test/
  standin.test.ts               its contract, on the second runner
  standin-parity.test.ts        the same refusals asked of the plane and the stand-in
docs/adr/0007-...md
docs/device-harness.md          the tier-3 procedure and where its results go
```

## 3. The stand-in authority

**[stated] Decision 3.** Node, at `cloud/standin/`, bundled by the existing esbuild step and
tested by vitest, so its named tests ride the second runner and docs-agree's union grows
without a third producer for them. It imports `handlers/identity.ts` unchanged, so the ref
grammar and the key derivation keep their one definition and ADR-0006 §2's rule is not
copied into a second language. Two riders:

- **(a) Built once.** esbuild bundles the stand-in to a single file in the cloud-stack job;
  the macOS job receives that file as an artifact and runs `node` on it. No second
  `npm ci`. This is the CI direction; the plan settles the mechanics.
- **(b) Its front half is measured against the plane's with one instrument.** The stand-in
  re-implements the four routes, because ADR-0006 §4 forbids running the real handlers over
  a stubbed `S3Client`. So the same refusal fixtures — no `sub`, `../etc`, a missing
  `uploadId`, an invalid part count — are asked of the four handlers and the four stand-in
  routes through one HTTP-request-to-event adapter, and the answers are asserted equal in
  one diff. A double that grew more lenient than the plane reds by name.

### 3.1 What it serves

The four routes, with the handlers' exact request and response shapes:

```
POST   /uploads                {ref, parts}       -> {uploadId}
POST   /uploads/{ref}/urls     {uploadId, parts}  -> {urls: [{partNumber, url}, ...]}
GET    /uploads/{ref}/parts    ?uploadId=         -> {parts: [n, ...]}
POST   /uploads/{ref}/complete {uploadId}         -> {etag}
PUT    <a url it issued>       the part's bytes   -> 200 and an ETag header
```

The URL it issues is a token bound to `(key, uploadId, partNumber, expiry)`, so the four
refusals below are decidable from the URL alone. The expiry is the plane's 900 seconds.

**It verifies no JWT.** The bearer token is taken as the `sub`. That is the stand-in
standing where `verifiedSub` stands, after authentication, and the spec says so because a
reader of the stand-in must not mistake it for an authorizer.

### 3.2 What it refuses

| Request | Answer | Mirrors |
|---|---|---|
| a URL used for another part, or after its expiry | 403 | ADR-0006 §4 falsifier 4 |
| an `uploadId` not under the key | 404 | falsifier 1 |
| `complete` over parts it does not hold | 400 | `TransportError.incompleteUpload` |
| what the plane refuses | the plane's status and body | §3 rider (b) |

Each of the first two is the stand-in's assumption about S3's behaviour and is recorded as
such in ADR-0007, beside the four falsifiers 4b already owns. A green stand-in test says
the stand-in behaves as assumed; it says nothing about S3.

A PUT for a part number already stored is **accepted**, and the earlier bytes are
replaced. That is S3's documented behaviour and the reason ADR-0001 wrote the invariant
against the weaker claim. The stand-in does not refuse the re-send; it counts it, which is
what keeps the negative control honest.

### 3.3 The honesty controls, on a prefix the production plane never has

```
POST /_standin/reset                         forget everything
GET  /_standin/uploads                       every uploadId it has seen, with its key
GET  /_standin/uploads/{uploadId}            {puts: {"1": 1, "2": 1, ...}, completes: n,
                                              held: [3]}
POST /_standin/hold    {part, mode}          mode: "after-store" | "before-store"
POST /_standin/release {part}
```

- **The PUT counter** is per `(uploadId, part)` and counts receipts, so a part re-sent after
  confirmation is a number the test reads and not an inference from timing or logs.
- **`hold` with `after-store`** stores the part, so `/parts` reports it, and withholds the
  answer. It is `InMemoryTransportDouble`'s stall-but-land case on a real socket, and it is
  how a kill is made to land mid-transfer without a sleep. Tier 2 uses only this mode.
- **`hold` with `before-store`** reads the body, stores nothing, and withholds the answer;
  on release it stores, then answers. Whether a killed app's task survives to be answered
  is the daemon's decision and the unverified fact, so this mode is the device harness's
  (§9) and never a CI assertion.

Nothing under `/_standin/` exists on the real plane, and the transport never calls it: the
UI test and the vitest suite are its only clients.

### 3.4 Where it binds

`127.0.0.1` on a port it chooses and prints, for the simulator, which shares the Mac's
loopback. `0.0.0.0` behind an explicit flag for the device harness, where the operator
types the Mac's LAN address into the app. The app's `Info.plist` allows local networking,
and whether loopback needs that exemption is an implementation unknown (§12).

## 4. The app

**[stated] Decision 4.** A committed `App/Dunnage.xcodeproj`, no generator. SwiftUI, iOS 17
floor as `Package.swift` says. One screen. The transport is a fourth package library and not
an app target; the app owns exactly what only an app can own. Two riders:

- **(a) `Local.xcconfig` is an optional include** — `#include? "Local.xcconfig"` from a
  committed `Shared.xcconfig` — and CI's simulator build with `CODE_SIGNING_ALLOWED=NO` is
  the proof that the project builds with the file absent. A fresh clone must not fail the
  way `cdk synth` did without `dist/`.
- **(b) The file the user picks is copied into the app's container, and `PayloadRef` names
  the copy**, never the picker's security-scoped URL. Whether the background daemon can
  read a scoped URL after relaunch, or copies the file itself, is an assumption this
  repository does not rely on, recorded as UNVERIFIED until the device harness observes it.

**Identity.** Bundle id `com.example.dunnage`. RFC 2606 reserves `example.com`, so the
reverse-DNS form carries no person's and no employer's identifier by construction.
`DEVELOPMENT_TEAM` is empty in every committed file. CI builds unsigned for the simulator.
A guard step in the app job greps the committed project and xcconfigs for a non-empty
`DEVELOPMENT_TEAM` and for `Local.xcconfig` itself, and fails on either; like 4a's
context-file check it is a guard and not a negative control.

### 4.1 What the app target owns

- the background session's identifier, `com.example.dunnage.background`, and its
  configuration, including the resource timeout in §5.4;
- the session's creation with the transport as its delegate, and the forwarding of
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` to the
  transport, which calls it back from `urlSessionDidFinishEvents`;
- the foreground session the control-plane calls go over;
- the container layout: `Application Support/ledger/` for `FileEventLog`,
  `Application Support/payloads/<hex upload id>` for the copy, and
  `Application Support/parts/<hex upload id>/<ordinal>` for chunk files. Application
  Support and not Caches, because Caches may be purged and a purged payload is an upload
  that cannot move;
- minting the `UploadID` (a UUID: randomness lives here, not in Core) and the
  `DestinationRef` (the same UUID's string, which the grammar admits);
- the bearer token, as a text field. Against the stand-in it is any string; against the
  real plane it is a Cognito token, which is 4b's to obtain;
- the base URL: a launch argument for the simulator, a text field for the device;
- running the driver. On launch and on return to the foreground the app enumerates the
  ledger's uploads and calls `resume` on each in turn. The driver is single-upload
  (ADR-0005), so the app runs them one at a time, and that is a limit stated here rather
  than a concurrency design.

### 4.2 The screen

A file picker, the token and base-URL fields, and one row per planned chunk showing
`planned`, `in flight`, `reported`, or `confirmed`, and a final line showing the upload's
phase. Each value carries an accessibility identifier of the form `chunk-3-status`, and the
UI test reads those and nothing else.

### 4.3 The precondition the UI test rests on

**What the screen shows is derived by replaying the ledger, plus the transport's in-flight
set for `in flight`.** The view holds no upload state of its own. That is not a style
preference: it is what makes "part 3 shows confirmed after relaunch" evidence about the
log, and the spec names it as the tier-2 test's precondition so that a later view model
that caches state is recognised as breaking the evidence and not merely the architecture.

### 4.4 Launch arguments the tests use

```
-standin-base-url <url>      the stand-in; absent in a device build
-token <string>              the bearer token
-quiet-after <seconds>       the driver's timeout; the UI test passes a value large enough
                             that no timeout fires inside the test, and every wait the
                             test itself takes is a bounded poll of the stand-in
-transport forgetful         the negative control, honoured only under #if DEBUG
```

## 5. The transport, and the correlation problem

**[stated] Decision 5**, with two riders (§5.4 and §5.5). Three facts the design rests on:

- a background session runs only upload and download tasks, from files. So the four
  control-plane calls go over a foreground session, and only the PUTs go over the
  background one. A control-plane call that fails when the process is running throws, and
  ADR-0005 §8 already says what that means: no event, and the next run asks again;
- each planned transfer is materialised as a chunk file, because a background upload task
  sends a whole file and a part is a span of the payload;
- `taskDescription` is the one string the system persists with a task across relaunch.

### 5.1 The task description

A JSON object with sorted keys, in the ledger's own style, naming the upload, the composed
session identity and the chunk ordinal:

```
{"chunk":3,"session":"<ref>/<uploadId>","upload":"<upload id>"}
```

JSON and not a joined string, because both the upload id and the composed session identity
may contain `/`, and a delimiter that either side may contain is a parse that is not total.
The encoder and decoder are pure and live in `TaskDescription.swift`; they are tier-1
tested under `swift test`.

**A task whose description this transport did not mint is cancelled and never read as
progress.** Missing fields, a chunk ordinal below one, a session identity that does not
parse: all three mean the same thing — not ours — and a task that is not ours is not
evidence about any upload.

### 5.2 At most one task per (session, chunk)

On creation the transport asks the session for its pending tasks and adopts each by its
description. From then on `send(transfer, in: session)`:

1. looks for an adopted or created task for `(session, chunk)`. If one is in flight, it
   awaits that task's completion and **does not create another**;
2. otherwise materialises the chunk file, obtains a URL for the part (§5.3), creates the
   upload task with the description above, and awaits it.

The await is a continuation the delegate resumes. **The driver's timeout cancels the await
and never the task.** The task's lifetime is the daemon's, bounded by the session's resource
timeout (§5.4). A transfer therefore outlives the driver that started it, which is the
sentence row 5 makes and the reason ADR-0005 §5 said the coincidence of "stopped waiting"
and "stopped" was a property of the double and not of the design.

### 5.3 URLs

`POST /uploads/{ref}/urls` signs every part from 1 to `parts` at once. The transport keeps
the answer in memory per session, hands each `send` the URL for its part, and asks again
when the answer is older than the plane's expiry or a task came back refused. The cache is
never on the log and never survives the process; a cold start asks again.

### 5.4 The delegate's mapping, and the stall bound

The delegate maps a task's completion to exactly one `TransferOutcome`:

```
no error, status 2xx         reportedComplete(chunk)
no error, any other status   refused(chunk)         an answer, and the answer was no
an error                     interrupted(chunk)     no answer arrived
```

The ETag header is not read. The device retains no ETag (ADR-0006 §4), and a header the
transport does not read is one the stand-in emits only because the wire it doubles does.

**A completion no `send` is awaiting** — one delivered after relaunch for a task the
previous process created — is held in memory, handed to the first `send` that asks for
that chunk, and otherwise never reaches the log. The log records answers a driver
received; a driver that never asked was never answered. Confirmed progress comes only from
`/parts`, whatever the delegate saw.

**[stated] Rider (a): the stall bound.** "Cancels the await, never the task" creates a
bound the way ADR-0005 O-9 did: an adopted task the daemon keeps retrying holds the chunk
until the resource timeout ends it, and every later `send` for that chunk awaits the same
task. The constant is named, given a reason, and recorded as this phase's O-10-shaped
exposure with a number on it.

The number is a ceiling and not an exact match, and the reason is worth stating exactly.
The resource timeout runs from the task's creation. The URL's 900 seconds run from its
minting, and `/urls` mints parts 1 to N at once, so every part after the first starts its
task with less than 900 seconds of URL life. **The real guarantee is the plane's, not the
timeout's:** a PUT presented with an expired URL is refused — 403, which the delegate maps
to `refused` — the driver records the refusal, asks the authority, and re-plans; the next
`send` for that chunk finds its cached URLs older than the expiry (§5.3) and mints fresh
ones. That path has a tier-1 test of its own, on the scripted wire, and it is what keeps a
stale URL from holding a chunk. The timeout is the bound on the other case, a task the
daemon never gets to present at all:

```swift
/// A part's URL is good for 900 seconds from minting (cloud/handlers/urls.ts,
/// EXPIRES_IN_SECONDS), and a task starts with whatever of that is left. A transfer that
/// is never presented inside the life of its URL can only end in a refusal, so the daemon
/// is given no longer than that life. 900 is the ceiling over it, not an exact match.
public static let partTransferLifetime: Duration = .seconds(900)
```

It is set as `timeoutIntervalForResource` on the background configuration, by the app.
The two 900s are in two languages, and nothing a compiler sees connects them; ADR-0007
records the coupling the way ADR-0006 §2 recorded the grammar's, with a reviewer as the
mechanism and a comment at each site naming the other. Whether the transport sets the
timeout to the URL's remaining life, or mints a URL at `send` so the two lives coincide, is
the plan's to settle and is recorded in O-13 as open.

### 5.5 Chunk files

**[stated] Rider (b).** A chunk file is deleted when `/parts` confirms the chunk, not when a
completion reports it, and the files that exist at once are bounded by the in-flight set.
That sentence is both the cache's lifecycle and its disk bound. A chunk file is written at
`send`, from `PayloadRef` and the plan's range; deleting any of them is always safe, because
the next `send` re-derives it. The payload copy itself is deleted when the upload reaches a
terminal phase.

### 5.6 `parseSession`

The Swift half of ADR-0006 §2, landing here. It splits the composed identity on the first
`/`; everything before is the ref, everything after is the uploadId. Exactly three inputs
are malformed — no separator, an empty ref, an empty uploadId — and each throws
`TransportError.unrecognisedSession` (§6.2). The call site carries the comment ADR-0006 §2
requires, naming `testARefContainingASeparatorIsRefused` as the only thing that keeps this
parse total.

## 6. Changes to Core and the ledger

### 6.1 `PayloadRef`, and ledger format 2

`UploadIntent` gains `payload: PayloadRef`, opaque to Core the way `DestinationRef` is:
never parsed, never compared structurally, never a source of authority. Its raw value is a
path relative to Application Support, so it survives the container moving. The app is the
only thing that resolves it.

`LedgerFormat.version` becomes 2, and `declared`'s payload gains `"payload"` inside
`"intent"`, which the decoder's `only(...)` list admits. **A version-1 header is refused
under ADR-0004 §4 rather than migrated.** No version-1 log exists outside the suite, so a
reader that defaulted `PayloadRef` for one would be a migration written for a file no one
has. The suite's fixtures move to version 2, and one named test keeps a version-1 header
refused with its version in the error.

`InMemoryTransportDouble` continues to synthesise bytes and ignores the ref, which is the
behaviour ADR-0006 O-12 said hid the gap; the double's doc comment now says so.

### 6.2 `TransportError.unrecognisedSession`

A new case, not `.unknownSession`. "This transport never minted this string" and "the
authority has forgotten the operation" are different facts that happen to strand the upload
the same way, and ADR-0006 §3 fixed what the case must not be: not a `TransferOutcome`, not
an interruption, never an abandonment. A thrown error satisfies all three under ADR-0005
§8. `TransportError` is not in the transition table, so the case costs no totality row.

## 7. The negative control

**[stated] Decision 6.** The control is `ForgetfulTransport`: `confirmedProgress` answered
from the completions this process saw, which after a relaunch is nothing, and never from
`/parts`. Everything else about it is the honest transport — the same sends, the same
refusals, the same task adoption. The failure it reintroduces is the thesis's own: the
driver re-sends parts 1 and 2 that the authority holds, and the stand-in's counter reads 2
for each, whatever the daemon did with part 3. It is deterministic across daemon behaviour,
which the other candidate — a session that forgets its tasks — is not: that one shows a
duplicate PUT only if the daemon kept the killed app's task alive, and on a daemon that
cancelled it, control and contract show the same number. Two riders:

- **(a) The triple keeps the roles phases 2, 3 and 4a gave it.**
  - *contract* — the forgetful transport keeps the contract it is measured against: same
    sends, same refusals, same task adoption; only `confirmedProgress`'s source differs.
    Tier 1, on the scripted wire, in the app's unit-test bundle.
  - *control* — the re-send counters at 2 for parts 1 and 2 after the kill and relaunch.
    Tier 2, in the UI-test bundle.
  - *contrast* — after the same relaunch-shaped reset, the honest transport answers
    `confirmedProgress` from `/parts`. Tier 1, scripted wire.

  The simulator kill-and-relaunch run is the phase's main claim and is listed once, under
  claim 4; the negative-control paragraph in `docs/invariants.md` points to it in prose
  rather than listing its name twice.
- **(b) The control lives in the app target only**, under `#if DEBUG` behind
  `-transport forgetful`, never in `DunnageTransport` — the same isolation as 4a's control
  under `test/`. It carries the sentence every control carries: it is never "fixed".

## 8. The claims

Ordered as they will appear in `README.md` and `docs/invariants.md`; `check 5 7`.

1. A background task names one chunk of one upload, and a task this transport did not name is never read as progress
2. A chunk has at most one transfer in flight, and a send for a chunk already in flight waits on it rather than starting another
3. What a session reported is an answer the driver received, and confirmed progress comes only from what the authority holds
4. A relaunched process derives its state from the log alone, asks before it sends, and re-sends nothing the authority confirmed
5. A cold start finds the payload on the log, and a chunk file is a cache bounded by the in-flight set
6. Phase 5's doubles keep the contracts they stand in for
7. The failure mode a transport that trusts its own reports reintroduces, kept working on purpose

Claim 4 is the simulator tier's one test and the phase's main claim. Claims 1, 2, 3 and 5
are tier 1, some under `swift test` and some in the app's unit-test bundle, and their
names say which fault was injected; the expired-URL path in §5.4 is filed under claim 3.
Claim 6 covers the stand-in's own contract, its parity with the plane (both vitest), and
the scripted wire double, and nothing of the control. Claim 7 is §7 whole: the forgetful
transport's contract test belongs there with the rest of its triple, as phases 2, 3 and
4a filed theirs.

Claims 1, 2, 3, 4 and 7 go red first, genuinely. The parity diff in claim 6 reds by making
the stand-in more lenient than the plane for one fixture and watching the diff name it.
The `DEVELOPMENT_TEAM` guard and the version-1 refusal are structural and carry the
one-line note the repository's rule allows rather than a manufactured failure.

## 9. The device harness

`docs/device-harness.md`, a numbered procedure, written in this phase and run by an
operator with a phone and a Mac on one network. Each step names what to do, what to read
off the stand-in's counters and the app's screen, and where to write it: the phase ledger,
and the "Observed on a device" section of ADR-0007, dated. No step is a test and none has
a test name. The steps:

1. **Background, then a kill by the system.** Start an upload with part 3 held
   `before-store`, background the app, let the system end it, foreground. Record whether
   the daemon finished the held PUT and whether the app was relaunched for the event.
2. **Force-quit.** The same, with the operator swiping the app away. Record the counters.
   This is the step that says what `FailureReason.userForceQuit` would mean; nothing in
   this phase appends it, and O-11's shape still holds.
3. **Airplane mode mid-transfer**, on and off within the stall bound, and once past it.
   Record whether the task ended at `partTransferLifetime` and what the next `send` did.
4. **The scoped-URL assumption** (§4 rider b): pick a file, kill, relaunch, and record
   whether the copy is what the daemon read.

Anything the procedure observes that contradicts a sentence in this spec or ADR-0007 is
written next to that sentence as an observation, and the sentence is not softened.

## 10. CI, and the README plan

**[stated] Decision 7.** A fifth job, `app-simulator`, and not steps in `build-and-test`: it
needs cloud-stack's stand-in bundle, boots a simulator, and asserts a different tier, and a
red tier 2 must not hide a green `swift test` or the reverse. Two riders:

- **(a) The simulator is booted as its own step** — `simctl boot`, then
  `simctl bootstatus -b` — before `xcodebuild test`, so first-boot time never counts
  against a test's own bound.
- **(b) `xcodebuild` writes a result bundle** (`-resultBundlePath`) and the job uploads it
  on failure, so a red on the simulator is diagnosable from the first run.

```
build-and-test (macos-26)        swift build && swift test
                                 unchanged; now covers DunnageTransport's pure halves
cloud-stack (ubuntu-24.04)       + bundles cloud/standin to one file and uploads it
app-simulator (macos-26)         needs: [cloud-stack]
                                 download the bundle; start it on 127.0.0.1 under a trap
                                 that stops it and prints that it did (R-b); create and
                                 boot a simulator on the newest iOS runtime the pinned
                                 Xcode ships; the DEVELOPMENT_TEAM guard; xcodebuild test,
                                 CODE_SIGNING_ALLOWED=NO, the port as a launch argument,
                                 -resultBundlePath; upload the bundle on failure
                                 -> uploads the app test-name list
docs-agree (ubuntu-24.04)        needs all three; three non-empty lists; one union;
                                 + check 5 7
commit-message-hygiene           unchanged
```

No Apple signing, no AWS, no network beyond loopback. The AWS scrub is inherited as-is.

**The third producer.** `xcodebuild -enumerate-tests -test-enumeration-style flat
-test-enumeration-format json`, present on Xcode 26.6 (checked locally), run before the
tests; the last path component cut and grepped as the other two producers do;
`LC_ALL=C sort -u`. docs-agree downloads three artifacts, checks each is non-empty, and
unions them. The enumeration lists what would run; a test that is skipped by configuration
is therefore an implementation unknown (§12).

### 10.1 The README plan, and the stale-sentence sweep

Each sentence that this phase makes false is assigned to the commit that makes it false,
so no docs-only commit is needed. Under R14, pointers cite and never re-record.

| Where | Today | Commit |
|---|---|---|
| `README.md` row 4b | "The bound holds against a real transport: after an interruption, redundant transfer is bounded by the chunks that were in flight and unconfirmed." | first: "The same transport, against the real plane and S3: the bucket exists, ADR-0006 §4's four assumptions and ADR-0007's three are checked by a recorded contract run, and O-10's recovery is decided." |
| `README.md` row 5 | "The invariant survives real lifecycle events. A simulated process death is not a SIGKILL, and phase 1 does not claim otherwise." | first: §1's wording, status `not started`; the landing commit sets the status |
| `README.md` bird's-eye, Transport box | `phase 4b  not built` — "owns the background URLSession, speaks S3 multipart against the presigned URLs the control plane issues" | first: `phase 5   not built` — "owns the background URLSession, speaks the plane's four routes: a stand-in here, S3 in 4b"; geometry held (field widths measured in the 4a ledger) |
| `README.md` bird's-eye, App box | `phase 5   not built` | landing: `landed` |
| `README.md` line 16 | "Nothing is deployed. No real transport, no app." | landing: "Nothing is deployed, and no byte has reached S3." |
| `README.md` lines 39–40 | "This package exists, the control plane exists as code only, and everything else is named so that its absence is legible." | landing: re-flowed whole (R-a) to say the app and the transport exist, the plane exists as code only, and the data plane is named so its absence is legible |
| `README.md` phase-5 section | absent | landing: the seven claims, and the command block: `cd cloud && npm ci && npm run build`, start the stand-in, `xcodebuild test` |
| `docs/adr/0005-...md` §1 "Where a real transport goes" | "To phase 4." | first: one line — the transport's phase is superseded by ADR-0007 §1; the lifecycle half's sentence stands |
| `docs/adr/0006-...md` §2, §3, "Deliberately not decided", O-12 | "4b" for `parseSession`, the `TransportError` case, `PayloadRef` | first: one line each, "moved to phase 5 by ADR-0007 §n" |
| `docs/adr/README.md` | six entries | first: ADR-0007, title matching its H1 (the known unenforced coupling) |
| `docs/invariants.md` line 413 | "4b's `parseSession`" | the commit that lands `parseSession` |
| the 4a spec §12 | lists `PayloadRef`, `S3UploadTransport` as 4b's | not edited; ADR-0007's supersession section names it, as ADR-0006 §9 did |

Sentences checked and left alone, with the reason: ADR-0004 §honesty and
`docs/invariants.md` line 135 say the device harness is phase 5's, which stays true;
`cloud/handlers/*.ts` and `docs/invariants.md` lines 317–399 say the contract run is 4b's,
which stays true; `README.md` line 173's "app" is the CDK app.

### 10.2 ADR-0007

Title: *ADR-0007 — The transfer that outlives the process, and the stand-in it is measured
against.* It records, in this order: the boundary and its four riders, naming the sentence
of ADR-0005 §1 it supersedes; the three tiers and the naming rule; the task description
and the one-task-per-chunk rule; the delegate's mapping and where an unclaimed completion
goes; the stall bound as **O-13**, with 900 seconds as its ceiling, the cross-language
coupling, and the timeout-versus-minting question open; the
chunk-file bound; `PayloadRef`, format 2 refusing 1, and `.unrecognisedSession`; the
stand-in's two S3 assumptions and its wire assumption, each UNVERIFIED and each assigned to
4b's contract run; the terminate signal and the daemon's treatment of a killed app's tasks
as **O-14**, UNVERIFIED; the scoped-URL assumption as **O-15**; an "Observed on a device"
section, empty at the first commit, that the harness fills with dated entries; and a
supersession section over the 4a spec's §12 in the shape of ADR-0006 §9.

### 10.3 The phase ledger

The phase-5 ledger opens by copying the standing rules R-a, R-b, R-c (as restated), R-d,
R-e and ruling R14 verbatim from the 4a ledger,
`.superpowers/sdd/read-in-this-order-precious-flurry/progress.md`, lines 233–239,
314–338, 1001–1013, 1384–1393 and 2049–2058. They are cited here and not copied
here, because a spec carrying a second copy would be the drift shape R14 refuses. That
directory is gitignored, so the copy is the ledger's own and the line numbers are read at
copy time.

## 11. Out of scope

The bucket. The deployed plane. A Cognito token in the app. The contract run against S3,
including the stand-in's three assumptions. O-10's recovery, which now has two demonstrated
needs and still one decision. More than one upload in flight at a time. A checkpoint.
Jitter. A per-chunk timeout. Any test that sleeps.

## 12. Open at the time of writing

Implementation unknowns, not ADR questions. Each resolves on the first run and is promoted
to ADR-0007 only if its answer constrains a later phase.

- Whether `127.0.0.1` needs `NSAllowsLocalNetworking`, or ATS exempts loopback on its own.
  The plist carries the key either way; which half is load-bearing is unknown.
- Whether `-enumerate-tests` lists a UI test that a test plan skips. If it does, the
  producer's reasoning differs from `vitest list`'s and the comment above it must say so.
- Whether the simulator's daemon delivers `didCompleteWithError` for a task adopted from a
  previous process, and whether `urlSessionDidFinishEvents` fires there at all. Claim 4 is
  written so that its assertions hold whichever way this goes; what changes is whether the
  unclaimed-completion path in §5.4 is exercised in CI or only on a device.
- Whether the newest iOS runtime on the macos-26 image at the time of the plan is the one
  the plan pins, and by what name `simctl create` knows it.
- Whether `timeoutIntervalForResource` on a background configuration counts while the app
  is suspended. O-13's number is right either way; what it bounds differs.
