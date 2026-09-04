# Dunnage

[![CI](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml/badge.svg)](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platforms: iOS 17, macOS 14](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-lightgrey.svg)
![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

Durable, resumable background uploads for iOS.

A successful HTTP request is not the same thing as a durable upload.

**Status:** Core, the durable ledger, the driver and the control plane — intent model,
total transition table, append-only event log with a file-backed implementation, the
transport boundary with an in-memory double, the driver that executes Core's effects
behind an injected clock, and a CDK stack with four handlers that synthesise with no
cloud credentials. Nothing is deployed. No real transport, no app.

Three mechanisms this library keeps apart, because none of them implies the others:

```
background URLSession    durable scheduling and execution across eligible background
                         lifecycle events
IETF resumable upload    byte-wise resumption, offset-shaped, and only against a server
                         that takes part in the protocol
S3 multipart             set-shaped: which part numbers the authority holds, which is
                         not a resumable byte offset
```

Core does not know whether confirmed progress is a contiguous byte offset or a set of
confirmed units. That meaning belongs to the transport contract, which is why the type is
a sum type rather than a number.

That boundary, and what "confirmed" means on each side of it, is
[ADR-0001](docs/adr/0001-transport-boundary-and-confirmed-progress.md). The other
decisions are in [docs/adr/](docs/adr/).

## Bird's-eye view

Where this package sits in the whole system. This package exists, the control plane
exists as code only, and everything else is named so that its absence is legible.

```
                            iOS device
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
     App                                         phase 5   not built
       choose a file, watch it finish
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
     Transport                                   phase 5   not built
       owns the background URLSession, speaks the plane's four routes
       against a stand-in here, the deployed plane and S3 in 4b
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
   ┌────────────────────────────────────────────────────────────────┐
   │  DunnageDriver                              phase 3   landed   │
   │    executes Core's effects, records what a transport           │
   │    answered, concludes nothing, and waits behind its own clock │
   └────────────────────────────────────────────────────────────────┘
   ┌────────────────────────────────────────────────────────────────┐
   │  DunnageLedger                              phase 2   landed   │
   │    the append-only event log, on a file                        │
   └────────────────────────────────────────────────────────────────┘
   ┌────────────────────────────────────────────────────────────────┐
   │  DunnageCore — pure                         phase 1   landed   │
   │    intent · chunk plan · confirmed progress as a sum type      │
   │    total transition table · resume plan · retry policy         │
   │    event log boundary · transport boundary · doubles           │
   └────────────────────────────────────────────────────────────────┘

   ═══════════════ the presigned URL boundary ═══════════════
   the device holds a short-lived URL, never an AWS credential.
   two different conversations leave it:

     JWT    ──▶  control plane   a session, part URLs, which
                                 parts the authority holds
     bytes  ──▶  data plane      the parts themselves

                               AWS
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
     CONTROL PLANE                               phase 4a  code only
       Cognito → API Gateway → Lambda
       issues short, narrow presigned URLs, and reports which
       parts S3 holds — s3:ListMultipartUploadParts stays here
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
     DATA PLANE                                  phase 4b  not built
       S3 multipart upload — which part numbers exist
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
```

DynamoDB is not in the picture. ADR-0006 §5 closes ADR-0001 O-2: S3's own part
enumeration answers what the control plane must answer to do its job, so the box
is absent because nothing needs one, not because nobody has decided. The one
thing it does not serve, idempotency, is a bounded storage cost.

## Progress

No percentages. A named invariant either exists or it does not.

| Phase | What it proves | Status |
|---|---|---|
| **1. Core** | A chunk the transport authority has confirmed is never re-sent, under an identity and payload contract Core does not interpret, and no two ways of not being confirmed are treated as one. | landed — 39 named tests |
| **2. Durable ledger** | The log outlives the process that wrote it: replaying it from disk reproduces state exactly, and a file that is not a log says so rather than deriving one. ADR-0001 O-1 was the open question here; ADR-0004 decides it. | landed — 21 named tests |
| **3. Driver** | The driver executes Core's effects and records what a transport answered, and concludes nothing of its own: a transfer it stopped waiting for is not a refusal, the attempt tally is not the driver's to keep, and an upload is given up on because Core asked for it. | landed — 22 named tests |
| **4a. Control plane** | The half of phase 4 a reader can check with no AWS account: a stack that synthesises without one, and a control plane that decides where a caller's bytes may land from the token it verified rather than from anything the caller sent. | landed — 23 named tests, vitest on a second runner |
| **4b. Transport and data plane** | The same transport, against the real plane and S3: the bucket exists, ADR-0006 §4's four assumptions and ADR-0007's three are checked by a recorded contract run, and O-10's recovery is decided. | not started |
| **5. App** | The bound survives the process: a transfer outlives the driver that started it, and a relaunched process resumes from the log alone and re-sends nothing the authority confirmed. CI's evidence is a real kill of a process on the simulator; suspension, jetsam and force-quit on a device are the harness's to record, never CI's. | not started |

## Phase 1: Core — a chunk the authority has confirmed is never re-sent

`swift test` runs all of them, with no AWS access key, no SSO session and no
cloud configuration of any kind. The named tests behind them are in
[`docs/invariants.md`](docs/invariants.md).

- A chunk names a fixed span, and an authority's answer is read against that span
- A confirmation is evidence about the upload and the operation it names, and nothing else
- A chunk the authority has confirmed is never handed to a transport again
- Every event resolves explicitly: a state and its effects, or a reason it changed nothing
- State comes only from replaying the log, and a cold start finds everything it needs there
- An interruption is not a failure, and a duplicate is not progress
- Giving up is a decision, taken against a budget that says what an attempt is
- The doubles keep the contracts they stand in for
- The failure mode the thesis claims to remove, kept working on purpose

## Phase 2: Durable ledger — the log outlives the process that wrote it

The second implementation of `UploadEventLog`, on a file. The protocol did not change to
suit it. The named tests are in [`docs/invariants.md`](docs/invariants.md).

- Every event has one written form on disk, and reading it back gives the event that was written
- A record naming an event this binary does not know is never guessed at
- The state derived by replaying from disk is the state the writer held
- A torn tail is not an event, and replay stops before it rather than at it
- Two uploads are never one ledger, however late in their identifiers they differ
- The failure mode a completeness marker removes, kept working on purpose

## Phase 3: Driver — it executes Core's effects and concludes nothing of its own

The driver: it executes Core's effects, records what a transport answered, and concludes
nothing of its own. Every test here runs against a scripted double and a clock that moves
only when a test moves it — no network, no real time. See
[ADR-0005](docs/adr/0005-the-driver-and-the-clock-it-waits-behind.md) for what that does and
does not establish. The named tests are in [`docs/invariants.md`](docs/invariants.md).

- A transport's answer becomes one event, on the log, before the next transfer begins
- The wait a send has earned is honoured before the transfer, by the driver's own clock
- A transfer that never answers is an interruption, and how long the driver waited is the driver's alone
- An upload picked up from the log asks the authority before it sends anything
- Giving up reaches the log because Core asked for it, and for no other reason
- Phase 3's doubles keep the contracts they stand in for
- The failure mode a driver that concludes reintroduces, kept working on purpose

## Phase 4a: Control plane — it decides where a caller's bytes may land from the token it verified

The control plane, and the half of phase 4 a reader can check with no AWS account. Nothing
here is deployed: every test reaches a pure function, an assertion about a synthesised
template, or the path a handler takes before it constructs a client — and no test in this
phase is evidence about any AWS account. See
[ADR-0006](docs/adr/0006-the-control-plane-and-the-identity-it-composes.md).

- The stack synthesises with no account, no region and no credential, and nothing it does can quietly acquire one
- A device holds no principal and no standing grant on the bucket: each authority it does hold names one operation on one part, and expires
- The object key is derived from the authenticated principal, and a field the client sends never reaches it
- A reference the caller supplies names a leaf inside its own prefix or it is refused, never repaired
- The control plane holds nothing its routes do not use, and every principal that can enumerate parts is one this stack defines and no device can become
- The failure mode a client-trusted key reintroduces, kept working on purpose

Everything above, on a machine with no AWS account, no SSO session and no cloud
configuration:

```
cd cloud && npm ci && npm run build && npm test && npx cdk synth --no-lookups
```

The build comes first because `cloud/cdk.json` is `{"app": "node dist/app.js"}` and
`cloud/dist/` is not committed, so in a fresh clone the synth has no app to run until
the build has written one; `--no-lookups` is the flag CI passes, and it guards against a
`fromLookup` arriving later rather than doing anything today.

## Phase 5: App — the transfer outlives the process that started it

The app, and the transport it owns: a background `URLSession` speaking the control plane's
four routes, against a stand-in here, the deployed plane and S3 in 4b. Three tiers, by
name — deterministic (`swift test` and the app's unit-test bundle: virtual clock, no
session, no socket), simulator evidence (one named test on the CI image, which kills the
process mid-transfer and reads the relaunch from outside), and the device harness (a
numbered procedure on a real iPhone, recorded and never a CI claim). See
[ADR-0007](docs/adr/0007-the-transfer-that-outlives-the-process-and-the-stand-in-it-is-measured-against.md)
for what each tier does and does not establish. The named tests are in
[`docs/invariants.md`](docs/invariants.md).

- A background task names one chunk of one upload, and a task this transport did not name is never read as progress
- A chunk has at most one transfer in flight, and a send for a chunk already in flight waits on it rather than starting another
- What a session reported is an answer the driver received, and confirmed progress comes only from what the authority holds
- A relaunched process derives its state from the log alone, asks before it sends, and re-sends nothing the authority confirmed
- A cold start finds the payload on the log, and a chunk file is a cache bounded by the in-flight set
- Phase 5's doubles keep the contracts they stand in for
