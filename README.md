# Dunnage

[![CI](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml/badge.svg)](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platforms: iOS 17, macOS 14](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-lightgrey.svg)
![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

Durable, resumable background uploads for iOS.

A successful HTTP request is not the same thing as a durable upload.

**Status:** Core and the durable ledger — intent model, total transition table,
append-only event log with a file-backed implementation, and the transport boundary with
an in-memory double. No real transport, no AWS, no app.

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

See `docs/adr/0001-transport-boundary-and-confirmed-progress.md`,
`docs/adr/0002-interruption-is-not-a-failure.md`,
`docs/adr/0003-what-an-attempt-is-and-where-time-enters.md`, and
`docs/adr/0004-the-on-disk-ledger-and-what-an-unreadable-record-does.md`.

## Bird's-eye view

Where this package sits in the whole system. One layer exists. Everything else is
named so that its absence is legible.

```
                            iOS device
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
     App                                         phase 5   not built
       choose a file, watch it finish
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
     Driver and transport                        phase 3   not built
       executes Core's effects, owns the background URLSession,
       speaks S3 multipart against presigned URLs
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
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
     CONTROL PLANE                               phase 4   not built
       Cognito → API Gateway → Lambda
       issues short, narrow presigned URLs, and reports which
       parts S3 holds — s3:ListMultipartUploadParts stays here
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
     DATA PLANE                                  phase 4   not built
       S3 multipart upload — which part numbers exist
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
```

DynamoDB is not in the picture. ADR-0001 O-2 leaves the question open, and drawing
a box for it would answer it.

## Progress

No percentages. A named invariant either exists or it does not.

| Phase | What it proves | Status |
|---|---|---|
| **1. Core** | A chunk the transport authority has confirmed is never re-sent, under an identity and payload contract Core does not interpret, and no two ways of not being confirmed are treated as one. | landed — 39 named tests |
| **2. Durable ledger** | The log outlives the process that wrote it: replaying it from disk reproduces state exactly, and a file that is not a log says so rather than deriving one. ADR-0001 O-1 was the open question here; ADR-0004 decides it. | landed — 18 named tests |
| **3. Driver and transport** | The bound holds against a real transport: after an interruption, redundant transfer is bounded by the chunks that were in flight and unconfirmed. | not started |
| **4. Control plane and data plane** | The device never holds an AWS credential, the server derives object ownership from the authenticated principal, and `cdk synth` runs with no cloud credentials. | not started |
| **5. App** | The invariant survives real lifecycle events. A simulated process death is not a SIGKILL, and phase 1 does not claim otherwise. | not started |

## Phase 1, invariant by invariant

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

## Phase 2, invariant by invariant

The second implementation of `UploadEventLog`, on a file. The protocol did not change to
suit it. The named tests are in [`docs/invariants.md`](docs/invariants.md).

- Every event has one written form on disk, and reading it back gives the event that was written
- A record naming an event this binary does not know is never guessed at
- The state derived by replaying from disk is the state the writer held
- A torn tail is not an event, and replay stops before it rather than at it
- The failure mode a completeness marker removes, kept working on purpose
