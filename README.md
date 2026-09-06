# Dunnage

[![CI](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml/badge.svg)](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platforms: iOS 17, macOS 14](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-lightgrey.svg)
![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

Durable, resumable background uploads for iOS.

A successful HTTP request is not the same thing as a durable upload.

**Status:** Core, the ledger, the driver, the control plane, the transport and the app
have landed. Nothing is deployed, and no byte has reached S3.

Three mechanisms this library keeps apart, because none of them implies the others:

```
background URLSession    durable scheduling and execution across eligible background
                         lifecycle events
IETF resumable upload    byte-wise resumption, offset-shaped, and only against a server
                         that takes part in the protocol
S3 multipart             set-shaped: which part numbers the authority holds, which is
                         not a resumable byte offset
```

Which of the three a transport speaks is the transport's to state and never Core's to
infer. The boundary is two declarations:

```swift
public enum ConfirmedProgress: Hashable, Sendable {
    case chunks(Set<ChunkID>)
    case offset(ByteOffset)
}

public protocol UploadTransport: Sendable {
    func openSession(for intent: UploadIntent) async throws -> TransportSessionID
    func send(_ transfer: PlannedTransfer,
              of intent: UploadIntent,
              in session: TransportSessionID) async throws -> TransferOutcome
    func confirmedProgress(for upload: UploadID,
                           in session: TransportSessionID) async throws -> Confirmation
    func finalize(_ session: TransportSessionID) async throws
}
```

That boundary, and what "confirmed" means on each side of it, is
[ADR-0001](docs/adr/0001-transport-boundary-and-confirmed-progress.md). The other decisions
are in [docs/adr/](docs/adr/), and the named test behind every claim below is in
[`docs/invariants.md`](docs/invariants.md).

## Bird's-eye view

Where this package sits in the whole system. A box is drawn around what is built and a
dashed rule around what is named and not, and the status column says what built has
reached: `landed` is invariants that exist and are checked, `code only` is code that
nothing has deployed. The data plane is named so that its absence is legible.

```
                            iOS device
   ┌────────────────────────────────────────────────────────────────┐
   │  App                                        phase 5   landed   │
   │  Transport                                  phase 5   landed   │
   │    owns the background URLSession                              │
   │  DunnageDriver                              phase 3   landed   │
   │  DunnageLedger                              phase 2   landed   │
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
| **1. Core** | A chunk the authority has confirmed is never re-sent, and two ways of not being confirmed are never one. | landed — 40 named tests |
| **2. Durable ledger** | Replaying the log from disk reproduces the state its writer held, and a file that is not a log says so. | landed — 21 named tests |
| **3. Driver** | It executes Core's effects and concludes nothing of its own — not a refusal, not the tally, not giving up. | landed — 22 named tests |
| **4a. Control plane** | The half of phase 4 a reader can check with no AWS account: a stack that synthesises without one, and a control plane that decides where a caller's bytes may land from the token it verified rather than from anything the caller sent. | landed — 23 named tests, vitest on a second runner |
| **4b. Transport and data plane** | The same transport, against the real plane and S3: the bucket exists, ADR-0006 §4's six assumptions and ADR-0007's three are checked by a recorded contract run, and O-10's recovery is decided. | not started |
| **5. App** | A transfer outlives the driver that started it, and a relaunched process resumes from the log alone. CI's evidence is a real kill on the simulator. | landed — 46 named tests, two app bundles on a simulator |

## Phase 1: Core — a chunk the authority has confirmed is never re-sent

`swift test` runs all of them, with no AWS access key, no SSO session and no cloud
configuration of any kind.

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
suit it.

- Every event has one written form on disk, and reading it back gives the event that was written
- A record naming an event this binary does not know is never guessed at
- The state derived by replaying from disk is the state the writer held
- A torn tail is not an event, and replay stops before it rather than at it
- Two uploads are never one ledger, however late in their identifiers they differ
- The failure mode a completeness marker removes, kept working on purpose

## Phase 3: Driver — it executes Core's effects and concludes nothing of its own

Every test runs against a scripted double and a clock that moves only when a test moves it —
no network, no real time. See
[ADR-0005](docs/adr/0005-the-driver-and-the-clock-it-waits-behind.md).

- A transport's answer becomes one event, on the log, before the next transfer begins
- The wait a send has earned is honoured before the transfer, by the driver's own clock
- A transfer that never answers is an interruption, and how long the driver waited is the driver's alone
- An upload picked up from the log asks the authority before it sends anything
- Giving up reaches the log because Core asked for it, and for no other reason
- Phase 3's doubles keep the contracts they stand in for
- The failure mode a driver that concludes reintroduces, kept working on purpose

## Phase 4a: Control plane — it decides where a caller's bytes may land from the token it verified

Nothing here is deployed: every test reaches a pure function, an assertion about a
synthesised template, or the path a handler takes before it constructs a client. See
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

Three tiers, and only the first two are CI's: deterministic tests, one simulator test that
kills the process mid-transfer, and a device harness that is recorded and never a CI claim.
See [ADR-0007](docs/adr/0007-the-transfer-that-outlives-the-process-and-the-stand-in-it-is-measured-against.md).

- A background task names one chunk of one upload, and a task this transport did not name is never read as progress
- A chunk has at most one transfer in flight, and a send for a chunk already in flight waits on it rather than starting another
- What a session reported is an answer the driver received, and confirmed progress comes only from what the authority holds
- A relaunched process derives its state from the log alone, asks before it sends, and re-sends nothing the authority confirmed
- A cold start finds the payload on the log, and a chunk file is a cache bounded by the in-flight set
- Phase 5's doubles keep the contracts they stand in for
- The failure mode a transport that trusts its own reports reintroduces, kept working on purpose
