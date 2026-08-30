# ADR-0004 — The on-disk ledger, and what a record this binary cannot read does

- **Status:** accepted
- **Date:** 2026-08-29
- **Scope:** the `DunnageLedger` module. No driver, no transport implementation, no app.
- **Builds on:** ADR-0001, which deferred event versioning to the on-disk format on the
  grounds that the format did not exist. It exists now, so **this document decides
  ADR-0001 O-1.**

## Context

`UploadEventLog` has had one implementation, in memory, in the test target. The log is the
single source of truth and state is a fold over it, so an in-memory log makes the whole
architecture a claim about one process. This module writes the second implementation, on a
file, and the protocol is unchanged: nothing in the file-backed log needed a method the
in-memory one did not.

A file that exists is not a log. Three ways it fails to be one, and they are not the same
thing:

```
torn      The last record is incomplete. Something stopped mid-write and the bytes end in
          the middle of an event. Nothing durably recorded that event.

unknown   The record is complete and well formed, and names an event this binary does not
          have. A newer build wrote it. Something did durably record an event, and this
          binary cannot say what it was.

absent    There is no file. A cold start with nothing yet, which `UploadEventLog` already
          says is not an error.
```

Collapsing torn into unknown, or either into absent, is the bug this document exists to
prevent. A torn tail read as a valid event derives state the authority never confirmed —
the thesis failing from the other end. Not re-sending confirmed bytes, but claiming bytes
were confirmed that were not.

## Decision

### 1. The format lives in the ledger module. Core gains no encoding conformance

Three options were on the table.

**(a) `Codable` synthesised on Core's types.** Rejected. The objection is not that a
conformance is I/O — it is not, and Core's purity rule would survive it. The objection is
that the bytes on disk would then be a consequence of Swift's synthesis rules applied to
Core's declarations: case names, associated-value labels, property names. Renaming a label
in Core is a refactor the compiler accepts and a format change no one wrote down, in a
module that does not know it owns a format.

**(b) A `@retroactive Codable` extension in the ledger module.** Rejected for the same
synthesis hazard, and for what the language is saying by demanding the attribute: neither
`Codable` nor `UploadEvent` belongs to this module, so a conformance may later appear in
Core and the two would disagree about which is in effect.

**(c) A hand-written codec in the ledger module, and no encoding conformance anywhere on
Core's types.** Chosen. The written form of each event is a decision recorded here and
implemented in one file, not a shape derived from how Core happens to spell itself.

The codec is asymmetric on purpose:

- The **encoder** switches over `UploadEvent` with no `default:`. Adding a case in Core is
  a compile error here, and whoever adds it has to choose its written form. A synthesised
  conformance would have invented one silently.
- The **decoder** has a default, and it is the unknown-event path in §4. That default is a
  decision, not an omission.

### 2. A record's completeness is decidable from the framing alone

Each record is length-prefixed and newline-terminated. Whether a record is complete is
answered by counting bytes, without parsing the payload.

This is the load-bearing property, and the reason is §4. Torn and unknown must stay apart.
If completeness meant "the payload parses", then a complete record this binary cannot
interpret and a half-written one would arrive as the same failure, and the only way to tell
them apart would be to guess.

Note what this rules out. Newline-framed JSON is *accidentally* resistant to a torn tail,
because JSON is self-delimiting and a truncated object does not parse. That resistance is a
property of the payload encoding, not of the ledger design: change the payload to anything
positional and it is gone, silently. A ledger that relies on its payload encoding to notice
a tear has not decided anything. The negative control in the suite is a ledger with no
completeness marker, and it is what that costs.

### 3. The format

```
ledger  := header record*
header  := "dunnage-ledger " version LF
version := 1*DIGIT
record  := length SP payload LF
length  := 1*DIGIT            ; the payload's length in bytes, decimal
payload := <length> bytes of UTF-8, a JSON object with sorted keys
```

Version 1. One file per upload, so that `records(for:)` reads one file and one upload's
writes never move another upload's bytes. The file is named by the lowercase hex of the
upload identifier's UTF-8, and hex rather than base64url because APFS is case-insensitive
by default: two identifiers whose base64url differs only in case would name one file. An
identifier whose name would not fit in a filename is refused rather than shortened or
hashed, for the same reason: a name that does not distinguish two uploads puts them in one
file, and arriving there by a length limit is no better than arriving there by case.

**The sequence number is not stored.** It is the record's position in the file. Writing it
down would create a second answer to a question that already has one, and then a rule for
what to do when the two disagree.

The payloads, one per event:

```
{"event":"declared","intent":{"destination":"d","plan":{"chunkSize":4,"totalBytes":20},
 "policy":{"initialBackoff":{"attoseconds":0,"seconds":1},"maxAttemptsPerChunk":3,
 "maximumBackoff":{"attoseconds":0,"seconds":60}},"upload":"u"}}
{"event":"transportSessionOpened","session":"s"}
{"chunk":1,"event":"chunkTransferReported"}
{"chunk":1,"event":"chunkTransferRefused"}
{"chunk":1,"event":"chunkTransferInterrupted"}
{"confirmation":{"progress":{"chunks":[1,2],"shape":"chunks"},"session":"s","upload":"u"},
 "event":"authorityReported"}
{"confirmation":{"progress":{"offset":16,"shape":"offset"},"session":"s","upload":"u"},
 "event":"authorityReported"}
{"event":"finalized"}
{"event":"abandoned","reason":"retriesExhausted"}
```

`ConfirmedProgress` is written with a `shape` tag and exactly the field that shape carries.
The sum type survives the round trip as a sum type; it does not become a record with two
optional fields on the way to disk and back.

### 4. ADR-0001 O-1: a record this binary cannot interpret refuses the whole replay

A complete record naming an event this binary does not have is not skipped, not guessed at,
and not read as far as it can be. `records(for:)` throws, naming the sequence and the tag it
could not read. So does `append`: writing new events onto a log whose contents this binary
cannot derive state from would produce a log neither binary can use.

The same answer covers a header naming a format version this binary does not know, and a
complete record whose payload is not what the format says.

**What this chooses, and what it costs.** Skipping an unknown record derives a state that
is wrong and looks fine — every later event folded against a history missing a step, with
no signal anywhere that it happened. Refusing derives nothing at all. That is worse for
availability: an older build cannot resume an upload a newer build started, and the user
sees an upload that will not move rather than one that quietly restarts. It is better for
the invariant, which is the trade this repository takes everywhere else, and it is the only
one of the two whose failure is visible.

**What this is not.** This is the ledger's answer for a record it cannot read. It is not a
general rule for every value the log carries that some component cannot interpret. A
`TransportSessionID` that does not parse is decoded correctly here — it is a `String`, and
neither this module nor Core reads it — so it poisons no fold, and refusing a replay over it
would discard correct state. ADR-0006 §3 decides that case and says why the answer differs.

This is a decision about *replay*, not a repair. Nothing is rewritten and nothing is
dropped. The ledger says it cannot read the log, and stops.

### 5. A torn tail ends the log, and the writer replaces it rather than writing past it

Reading stops **before** the first incomplete record, not at it. The events before it are
whole and durable; the torn bytes never became an event, because the write that would have
made them one did not finish.

The writer, before appending, truncates the file to the end of the last complete record.
This is not "mutating or dropping an event to repair state": the only bytes it ever removes
are bytes that are not a record, and it does so because appending past them would leave
unreadable bytes in the middle of the file, where a reader that stops at the first
incomplete frame would never reach the records after them.

Two assumptions this rests on, stated rather than assumed:

- **Single writer, append-only, no seeking.** The file is therefore always a prefix of the
  byte stream the writer intended, so an incomplete record can only be the last one.
- **A truncation is a short prefix, not arbitrary bytes.** Enough payload bytes present but
  the terminator missing is therefore not a tear — the bytes were there — and it is refused
  under §4 rather than trimmed.

## The honesty boundary

Everything here is tested by constructing a file and asserting what replay does with it. No
test in this phase kills a process, and none may be named or described as if it did. A
truncated file is a fault the suite injects deterministically; a real `SIGKILL` mid-`write`
is a lifecycle event, it belongs to the device harness in phase 5, and the two are not
evidence of the same thing. What the suite establishes is that *given* a file with a torn
tail, replay derives the state the last complete record produced. Whether a process death
produces exactly that file on APFS is not established here.

`fsync` is likewise the strongest durability action available from user space, and this
module takes it after every append. That it survives a power loss is a claim about the
device, and no test in this repository makes it.

## Deliberately not decided

- **No checksum.** The framing detects truncation, which is the failure this phase models.
  It does not detect a bit flip inside a payload; that is a different claim needing a
  different mechanism, and adding one now would answer a question nothing has asked.
- **No checkpoint.** State is still derived by replaying the whole file. A checkpoint
  remains allowed later as a disposable cache reconstructible from the log, and it is not
  this phase — introducing it here would create the parallel authority the architecture
  forbids.
- **No migration.** Format version 1 is the only version, and the reader refuses anything
  else rather than translating it. A second version needs a reader that has seen two, and
  there has only ever been one.

## Open questions

### O-6. The directory entry of a new ledger file is not itself fsynced

`fsync` on the file handle does not guarantee the directory entry that names a newly
created file is durable. A power loss can therefore lose a ledger file whole, which reads
as `absent` — a cold start with nothing.

Worth noting that this fails safe *for the thesis*: an upload whose log vanished re-sends
everything rather than skipping a chunk nobody confirmed. It is an availability gap, not a
correctness one, which is why it is recorded rather than closed today.

### O-7. Enumeration reads the directory, and the directory is not the log

`uploads()` lists files and decodes their names. A file the module did not write, named
`*.ledger`, is refused rather than ignored, on the same "never guess" grounds as §4 — but
that makes an unrelated stray file able to stop enumeration for every upload. Whether that
is the right blast radius is not settled; nothing yet writes into that directory but this
module.
