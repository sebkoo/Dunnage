# Dunnage

Durable, resumable background uploads for iOS.

A successful HTTP request is not the same thing as a durable upload.

**Status:** Core only — intent model, total transition table, append-only event log, and
the persistence and transport boundaries with in-memory doubles. No real transport, no
AWS, no app.

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

See `docs/adr/0001-transport-boundary-and-confirmed-progress.md`.
