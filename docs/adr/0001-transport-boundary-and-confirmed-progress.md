# ADR-0001 — The transport boundary, and what "confirmed" means on each side of it

- **Status:** accepted
- **Date:** 2026-08-29
- **Scope:** `DunnageCore` only. No transport implementation exists yet.

## Context

Dunnage's thesis is a bound on redundant work:

> This library never re-sends a chunk after that chunk has been positively confirmed by
> the transport authority. Redundant transfer is bounded by the set of unconfirmed
> in-flight chunks, under the transport's stated contract.

That sentence is only meaningful if "positively confirmed by the transport authority" has
a precise definition. It does not have one definition. It has two, and they are not
interchangeable.

Three mechanisms are routinely collapsed into one another. They are separate:

```
background URLSession      Durable scheduling and execution across eligible background
                           lifecycle events. The system continues transfers while the app
                           is not running and relaunches it to deliver events. It does not
                           define durable application progress, does not reconcile progress
                           against an arbitrary backend contract, and does not guarantee
                           completion under every lifecycle event.

IETF resumable upload      Byte-wise resumption. Offset-shaped. Requires the server to
                           participate. URLSession implements the client half; with a
                           background configuration the resumption is handled
                           automatically, but only when the server speaks the protocol.
                           Against a server that does not, URLSession cannot provide
                           byte-wise resumability, and recovery follows whatever the
                           transport contract defines — which may mean re-transfer.

S3 multipart               Set-shaped. The authority reports which part numbers it holds.
                           There is no resumable byte offset.
```

None of the three implies the others.

## Decision

### 1. Confirmed progress is a sum type, and Core does not know which case it will get

```swift
public enum ConfirmedProgress: Hashable, Sendable {
    case chunks(Set<ChunkID>)   // set-shaped authority   — e.g. S3 multipart part enumeration
    case offset(ByteOffset)     // offset-shaped authority — e.g. IETF resumable upload
}
```

The two confirmation models are mutually exclusive: **one transport contract yields exactly
one case.** They are therefore cases, not fields.

A struct exposing both — `chunks: Set<ChunkID>?` alongside `offset: ByteOffset?` — is
rejected. It makes "both present" and "neither present" representable, which forces Core to
carry a runtime rule for states the transport contract says cannot exist. The sum type
deletes those states at compile time instead.

"Part 5 exists" and "bytes 0 through 5 are contiguous" are different claims about different
things. Core must not collapse them into a single number, and must not translate one into
the other. The meaning belongs to the transport contract; Core carries it unmodified and
plans against whichever case it was handed.

### 2. A confirmation names what it is a confirmation *of*

```swift
public struct Confirmation: Hashable, Sendable {
    public let upload: UploadID              // which upload
    public let session: TransportSessionID   // which transport operation stated it
    public let progress: ConfirmedProgress   // what the authority guarantees
}
```

A confirmation is authoritative only under the transport's stated identity contract. A
confirmation belonging to one upload identity, or to one transport operation, is never
silently applied to another.

`session` is present because S3 part numbers are scoped to a multipart `uploadId`: part 3
of upload operation A and part 3 of upload operation B are unrelated facts. It is **not** a
generation or revision counter, and no such counter is introduced. See "Deliberately not
decided" below.

### 3. Core asks the boundary; it never infers progress from bytes it handed over

"The transport reported the transfer finished" and "this unit is durably known to exist"
are different statements. Core records the first as an observation and advances confirmed
progress only on the second. A transport that reports completion for bytes the authority
never durably stored will therefore not cause Core to skip that chunk.

### 4. The boundary protocol

The boundary is declared in Core and implemented outside it. Core's transition function is
pure and never calls it; transitions return effects as data and a driver executes them.

```swift
public protocol UploadTransport: Sendable {
    func openSession(for intent: UploadIntent) async throws -> TransportSessionID
    func send(_ transfer: PlannedTransfer, in session: TransportSessionID) async throws -> TransferOutcome
    func confirmedProgress(in session: TransportSessionID) async throws -> Confirmation
    func finalize(_ session: TransportSessionID) async throws
}
```

`finalize` is a distinct operation because **an uploaded part is not a completed object.**
On S3 the object does not exist until `CompleteMultipartUpload` succeeds; until then the
uploaded parts occupy storage and no object has been created. A boundary that omitted
finalization would encode the false belief that transferring the last chunk completes the
upload.

## What this buys, and what it does not

### S3 is an authority, but it is not the application's upload ledger

S3 is authoritative **about the multipart state it exposes** — which part numbers it
currently holds for a given `uploadId`. It does not thereby become the application-level
record of the upload. The protocol itself is the evidence: `CompleteMultipartUpload`
requires the *client* to supply the list of part numbers and ETags it kept. If S3 were a
sufficient ledger, it would not need the client to hand that list back.

Consequently the append-only event log on the device is the application's source of truth,
and transport observations are inputs to it:

```
transport / storage state
        │  observation (event, poll, response)
        ▼
    observation
        │  explicitly defined reconciliation rule
        ▼
  application state
```

An observation never mutates state on its own.

### The gap: "part 5 exists" is weaker than "my payload is part 5"

S3 permits re-uploading the same part number; the later upload overwrites the earlier one.
So for a given `uploadId`:

- *Part 5 exists* — S3 will state this.
- *The payload this upload intended is the bytes stored as part 5* — S3 will not state this
  from part enumeration alone.

Part enumeration returns the part number, size, ETag and last-modified time. Matching a
retained per-chunk ETag against enumeration would let a client raise its claim toward the
stronger one, but that is a client-side check against a value the client kept, not a
guarantee the authority makes.

**The invariant is written against the weaker claim.** Core's rule is "a confirmed chunk is
never rescheduled," scoped to the transport's own identity contract. Core does not today
assert that the confirmed bytes are the bytes this upload intended. Closing that gap
requires per-chunk content verification the client keeps itself, and is not in scope.

`ETag` is not an application content hash. For a multipart object the ETag is not the MD5
of the whole file. Integrity verification, if required, means the application computes and
retains its own digest (e.g. SHA-256). ETag is a transport-level identifier only.

### Ownership is derived server-side

Where a control plane issues presigned URLs, **the server derives object ownership from the
authenticated principal, not from client-supplied path fields.** A request body containing
`uploads/<user-id>/...` is not evidence of anything. This constrains the control plane, not
Core, and is recorded here so the constraint is not rediscovered later.

## Open questions

### O-1. How does a stored event log survive a binary that has since gained enum cases?

The log outlives the process that wrote it. Events are never rewritten. The transition
table's totality is checked against *today's* cases. A future build that decodes a log
containing a case it does not know, or an older build decoding a log written by a newer one,
is a real and currently unhandled gap.

This is not solved by the current design and is not solved today. Recording it as open.

**Deliberately not decided:** no version field is added to the event type today. Event
versioning is coupled to the on-disk ledger format, which does not exist yet; deciding it
now would fix a format against an unwritten writer.

### O-2. Where does the server-side upload record live?

Candidate answer: one item per upload in a key-value store (DynamoDB). But S3's own part
enumeration may already be sufficient, in which case no database is needed at all. The
question is whether the control plane requires application-level queries, ownership
records, idempotency state, or lifecycle tracking that S3 cannot serve efficiently.

Not chosen today. Introducing a database before the need is demonstrated would be
speculative.

### O-3. UNVERIFIED — the published status of the IETF resumable upload specification

This ADR refers to the protocol as `draft-ietf-httpbis-resumable-upload`. Whether it has
since been published as an RFC, and under what number, has not been verified in this
session. The architectural claim here does not depend on the answer — what matters is that
the mechanism is offset-shaped and requires server participation — but the citation should
be corrected before this document is quoted externally.

## Deliberately not decided

- **No generation or revision counter.** `TransportSessionID` on `Confirmation` scopes a
  confirmation to the transport operation that stated it, because part numbers are scoped
  to a session in the underlying contract. A monotonic generation counter that would order
  *stale observations against each other* is a different mechanism, needs a state-model
  invariant that requires it, and is not introduced.
- **No checkpoint record.** State and the resume view are derived by replaying the log. A
  checkpoint may later exist as a performance cache, reconstructible from the log and
  disposable. It is never a parallel authority.
- **No clock.** No invariant in the current scope depends on time, so no clock protocol is
  injected yet. Timestamps on events are deferred with the on-disk ledger (O-1).
