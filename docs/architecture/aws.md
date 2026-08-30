# Architecture decision — the cloud boundary

This document records **decisions**: why the cloud boundary is drawn where it is. The rules
an agent has to follow are in `CLAUDE.md`. Do not mix the two.

## Three planes

Separate three responsibilities. This is the most important distinction in the project.

```
CONTROL PLANE — who may upload what, and where
─────────────────────────────────────────────────────────
 iPhone
   │ Access token (JWT)
   ▼
 Cognito user pool          Issues the access token (1 hour by default, configurable)
   │
   ▼
 API Gateway (HTTP API)     JWT authorizer verifies signature, iss, aud/client_id, exp, scope
   │
   ▼
 Lambda
   ├── Creates the upload session
   ├── Issues a presigned URL per part (short expiry, the caller's own prefix only)
   │     └── The URL is itself a bearer-shaped grant. Whoever holds it can
   │         perform that operation until it expires, so treat it as a secret
   └── Queries which parts the server actually holds   ← the backend does this in this
   │                                                     design (s3:ListMultipartUploadParts
   │                                                     stays in the control plane)
   ▼
 S3 multipart upload        Which parts actually exist


APPLICATION TRUTH — what happened
─────────────────────────────────────────────────────────
 Dunnage event log (on the device)
   └── intent / attempts / confirmations / failures


OPTIONAL CONTROL-PLANE STATE
─────────────────────────────────────────────────────────
 [DynamoDB, if the need is demonstrated]
   └── only where application-level queries, ownership, idempotency or
       lifecycle tracking are not served efficiently by S3 alone
```

### Why split it this way

```
Uploaded part   ≠   Completed object
```

Every part can be uploaded and the object still does not exist until `CompleteMultipartUpload` succeeds, and the uploaded parts occupy storage in the meantime. This project's thesis is about exactly that gap.

**`S3 ObjectCreated` is not "the upload succeeded."** For multipart, the object comes into existence only when `CompleteMultipartUpload` succeeds. The event signals *that a completed object was created in S3*, which is not the same claim as *the user's whole workflow succeeded*.

**Dunnage separates local intent, transport authority, and cloud coordination.**

Three further things have to be pulled apart on the transport side.

```
background URLSession        Schedules and continues transfers across eligible background
                             lifecycle events
IETF resumable upload        Byte-wise resumption. Offset-shaped. Requires the server to
                             take part (URLSession implements the client half)
S3 multipart                 Set-shaped: which part numbers. Not a resumable byte offset
```

None of the three implies the other two. That is why Core does not know whether confirmed progress is an offset or a set; the transport contract fixes that meaning. Calling them three planes makes the explanation much easier — use the same term in the README and the ADR.

| Plane | What it owns | What it is authoritative about |
|---|---|---|
| **Control plane** | Authorization and coordination — Cognito, API Gateway, Lambda, (DynamoDB if needed) | Who may query whose upload and receive URLs |
| **Data plane** | Bytes — S3 multipart | Which **parts** storage reports it holds |
| **Local plane** | Client intent and history — the event log | What the user intended, when, and what happened |

S3 is authoritative **only about the multipart state it exposes**. It does not thereby become an application-level upload ledger — the evidence is that `CompleteMultipartUpload` itself requires the client to hand back the list of part numbers and ETags it kept. And neither side alone is a complete ledger.

**An event is an observation, not grounds for a state transition.**

```
S3 state
    ↓  event / poll
observation
    ↓  an explicitly defined reconciliation rule
application state
```

`ObjectCreated` means **"S3 reported that a completed object exists."** That is evidence about the data plane, not proof that the whole application workflow succeeded.

So when is it a success? Application state is derived like this:

> Application state is derived by replaying the event log and applying explicitly defined reconciliation rules to transport observations.

The event log is the authority, transport observations are inputs, and the transition rules combine the two. A single event never changes state by itself.

**Do not treat ETag as an application content hash.** The ETag of a multipart object is not the MD5 of the whole file. Where integrity verification is required, the application computes and keeps its own digest (e.g. SHA-256). Leave one line in the ADR: `ETag ≠ application content hash`.

## Presigned URLs, and where ownership is decided

The device is not given S3 credentials. An app carrying them lets whoever opens the binary reach someone else's prefix. Lambda issues a short, narrow URL per request instead, so a leaked URL is bounded in what it can do.

"The caller's own prefix only" is not guaranteed by the act of issuing a URL. It has to come down to an implementation contract:

```
authenticated principal
        ↓
verify ownership of the upload
        ↓
the server derives the object key
        ↓
a presigned URL valid only for that key and that operation
```

One line for the ADR: **The server derives object ownership from the authenticated principal, not from client-supplied path fields.** An `uploads/<user-id>/...` in the request body is not evidence of anything.

## Why the bytes do not pass through the server

Not because Lambda cannot receive them. **It can, and this design deliberately does not use it that way.** The primary reason is the separation of control plane from data plane: Lambda coordinates the upload and does not carry the bytes. Lambda execution time, memory, cost and throughput follow from that, including the 900-second maximum execution time — but those are consequences, not the reason.

## Why the device does not query resume state itself

S3 does not prevent it; **this design does not arrange it that way.** `ListParts` is a separate S3 API call requiring `s3:ListMultipartUploadParts`, and a per-part presigned PUT URL is not a means of authorizing that call. The permission stays in the control plane and the device uses the progress view the backend hands it. A client holding suitable credentials could make the call — the decision is not to put the device in that position.

## Decided — the control plane does not need DynamoDB

Answered in `docs/adr/0006-the-control-plane-and-the-identity-it-composes.md` §5, which closes ADR-0001 O-2. Once the control plane's four routes were written down, the questions it has to answer could be enumerated rather than estimated, and every one it must answer to serve those routes is served by S3's own part enumeration and by a key the server derives from the authenticated principal. **No database is introduced.**

The honest remainder is idempotency. A create request retried after its response was lost opens a second multipart operation, and nothing in S3 dedupes it. That is ADR-0005 O-8 — a storage cost at the authority and not a correctness one, because no confirmed chunk is re-sent — and the bucket's `abortIncompleteMultipartUploadAfter` rule bounds it. If it ever has to be *prevented* rather than bounded, that is the demonstrated need this section spent its life asking for, and O-2 reopens with a reason rather than a hunch.
