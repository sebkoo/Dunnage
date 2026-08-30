# ADR-0006 — The control plane, and the identity it composes

- **Status:** accepted
- **Date:** 2026-08-30
- **Scope:** the `cloud/` CDK application and its handlers. Nothing is deployed. No AWS
  account is touched.
- **Builds on:** ADR-0001, whose O-2 is closed by §5. ADR-0004, whose §4 answer §3 diverges
  from — the scope paragraph that corrects it lands in the same commit as this document.
  ADR-0005, whose O-10 is given a size by §7.

## Context

Phase 4 is split. 4a is the half a reader with no AWS account can check: a CDK application,
four Lambda handlers, template assertions, and CI that runs all of it with the AWS
environment scrubbed. 4b is the transport and the data plane — a bucket that exists in an
account, `S3UploadTransport`, and a contract run recorded against a real service.

The split is what makes this document necessary rather than tidy. Decisions taken in 4a are
kept, or broken, by 4b: in another language, in another test suite, in another phase.
Nothing a compiler or a test runner sees connects the two halves. Where phases 1 to 3 could
leave a rule in a type and let the compiler enforce it, this phase cannot, and the rules
that survive that seam have to be written down somewhere both halves are read from.

Three of them are here. A grammar rule that keeps a Swift function total (§2). A refusal
that looks like ADR-0004 §4's and is decided the other way (§3). A teardown procedure that
has to exist before anything is created (§6).

## Decision

### 1. This document precedes the first handler, and the ordering is load-bearing

The repository's habit already points this way: ADR-0004 landed before the ledger module,
ADR-0005 before the driver. Two reasons here are stronger than habit.

**The grammar rule and the parse it protects are in different languages, suites and
phases.** §2 composes a transport session identity out of a `DestinationRef` and an S3
`uploadId`, joined by `/`. The Swift function that splits it is total over the identities
this transport mints, and no minted identity carries a `/` in its ref — not because
`DestinationRef` forbids one, since it holds a `String` and accepts anything, but because the
server refuses such a ref and so never returns an uploadId to compose with it. The only thing
that keeps *that* true is a TypeScript regex in `cloud/handlers/identity.ts` and the test
that pins it. `swift build` never reads that file; `npm test` never reads the parse.
Relaxing the ref grammar to admit a `/` would make a Swift function ambiguous, silently,
from a TypeScript edit, and the only
surviving guard would be a test whose name does not mention the parse. Written beside the
regex, the rule is a comment on one side of a seam. Written here, it is the reason the regex
is what it is.

**§3 diverges from ADR-0004 §4, and ADR-0004 §4 states its answer as this repository's
rule.** ADR-0004 §4 calls refusing the whole replay "the trade this repository takes
everywhere else." The transport 4b writes will not take it: a `TransportSessionID` that does
not parse refuses one call and no replay. Until that sentence is scoped, the repository
states a rule its own next module breaks, and a correction cannot follow the code that
breaks it. So ADR-0004 §4 gains its scope paragraph in the same commit as this document,
before either has any code to describe.

### 2. The composed session identity, and the separator a ref may not contain

```
TransportSessionID.rawValue  ==  <destinationRef> "/" <s3UploadId>
```

`TransportSessionID` is opaque to Core: never parsed, never compared structurally, only
carried and handed back. The transport is therefore free to decide what is in it, and it
puts both of the things the server needs there.

**Why it exists.** After a process death the driver replays the log, recovers the session
identity from `transportSessionOpened`, and calls `confirmedProgress(in:)`. That call
receives the session identity **and nothing else** — not the intent, so not the
`DestinationRef`. Without the composition the transport cannot name the object key, and the
server cannot answer the one question a cold start asks. The alternative is §5's row for
*what is the key, given only an uploadId* — a `ListMultipartUploads` scan under the caller's
prefix, on the hot path, to recover a key the client already knew.

**The coupling, stated here at the definition and not only beside the regex.** The ref
grammar is

```
^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$
```

and `/` is outside that character set on purpose. That exclusion is not a sanitising
nicety — it is the totality condition for the parse. Two symbols stand on it, and neither
runner sees the other:

- `testARefContainingASeparatorIsRefused` — TypeScript, 4a. The only thing that enforces the
  rule.
- `parseSession` — Swift, 4b. The only thing that breaks when the rule breaks. It guards
  nothing; it is what the guard is for.

Each call site carries a comment naming the other when it is written. The rule itself lives
here, because a comment cannot be the thing a reviewer of the *other* file is expected to
have read.

**The parse splits on the first separator.** Everything before the first `/` is the ref;
everything after it is the uploadId, whatever it contains. An identity with two separators
is therefore **not** malformed. It is an uploadId that contains a `/`, and it parses
correctly. S3's multipart upload id is an opaque token: splitting on the last separator, or
refusing a second one, would encode a guess about a vendor's format that S3 has never
promised.

**Exactly three inputs are malformed** — no separator at all, an empty ref, an empty
uploadId. All three mean one thing: *this transport never minted this string.* `openSession`
is the only place an identity is created, and it always creates a well-formed one. The list
is three and not two only while §4's third falsifier holds: an `UploadId` that could come back
empty would make `ref + "/"` a string this transport really had minted.

`TransportSessionID`'s doc comment in Core says "On S3 multipart this is the `uploadId`".
After this section that example is no longer exact — the raw value identifies the operation
and contains the uploadId, but is not it. The type is unchanged, because Core still never
reads inside it. Correcting the comment is a code change and belongs to the commit that
writes the transport.

### 3. A session identity that does not parse refuses one call, and nothing else

The identity comes off the log, so the question has ADR-0004 §4's shape: a value this binary
cannot interpret, read back from a durable record. It is decided the other way, and the
difference is the reason ADR-0004 gave for its own answer.

ADR-0004 refuses a replay because an undecodable record poisons the fold. Every later event
is folded against a history missing a step, so the derived state is wrong and looks fine.
Refusing derives nothing, which is worse for availability and better for the invariant, and
that trade is taken because the failure is visible.

A session identity that does not parse poisons nothing. The ledger decoded it correctly —
it is a `String`, and nothing outside the transport looks inside it. Core does compare one
to another, whole: that is how ADR-0001 §2 scopes a confirmation to the operation that
stated it, and `UploadTransition` rejects a confirmation from another operation on exactly
that equality. An equality test over an opaque whole does not care whether either side
parses, and nothing anywhere folds over the string's parts. The replay is exact, the
derived state is right, the attempt tally is right, and every other upload on the log is
untouched. The only thing that cannot proceed is the next transport call for this one
upload. Refusing the whole replay would discard correct state to punish a string that
exactly one component in the system understands.

So the transport throws at its own boundary. Under ADR-0005 §8 the driver appends nothing
and stops, and the upload is unable to move — which is the same shape as ADR-0005 O-10, an
authority that has forgotten the operation. Both wait on the same 4b decision: what it means
to open a second transport operation for an upload that already has one. Neither is a
failure. That the two land in one place is a property of the design, not a coincidence.

**What 4a records, and what it does not decide.** Whether this needs a new `TransportError`
case or reuses `.unknownSession` is 4b's, because it is a change to Core and the transport
that demonstrates the need does not exist yet. What is fixed here is what the case must not
be:

- **not a `TransferOutcome`** — it is not an answer about a chunk, so it becomes no event;
- **not an interruption** — an interruption is an event about a chunk whose transfer was
  attempted and did not answer. No transfer was attempted here, so recording one would put
  a claim about a chunk on the log that nothing made;
- **never an abandonment** — giving up is Core's conclusion (ADR-0003 §5), reached against a
  budget derived from the log, and a transport does not reach one.

### 4. Four routes, `finalize` in the control plane, and no stubbed `S3Client`

```
POST   /uploads                {ref, parts}       CreateMultipartUpload    serves openSession
POST   /uploads/{ref}/urls     {uploadId, parts}  a presigned PUT per part serves send
GET    /uploads/{ref}/parts    ?uploadId=         ListParts                serves confirmedProgress
POST   /uploads/{ref}/complete {uploadId}         ListParts + Complete     serves finalize
```

**`finalize` is a control-plane call, not a device call.** `CompleteMultipartUpload`
requires the caller to hand back the `(PartNumber, ETag)` list, and the device retains no
ETags. It must not start retaining them: ADR-0001 states `ETag ≠ application content hash`,
so an ETag ledger on the device would be a per-chunk store of transport-level identifiers
that the application is not entitled to read as content, kept only so the device could make
a call the control plane can make from what S3 already reports. The Lambda calls `ListParts`
and completes from the authority's own answer.

Two consequences worth naming. `s3:ListMultipartUploadParts` stays in the control plane,
which `docs/architecture/aws.md` already decided and this route confirms rather than
revisits. And the device cannot complete an object over parts it never sent.

**There is no stubbed `S3Client`, and none may be added.** A stub is a double of a vendor's
product. This repository cannot state that contract: writing one would encode a guess about
AWS's behaviour and then run the guess against itself, which produces a green suite that has
checked nothing. The precedent is the commit that landed the transport double — *the double
implements the transport contract, not a vendor's product.* An `UploadTransport` double
stands in for a boundary this repository declared and can therefore specify. An `S3Client`
double would stand in for AWS.

**What would falsify that in 4b.** The handlers written in this phase assume four things
about S3 that nothing in this phase checks. Each is checked by 4b's contract run against a
real bucket, and that run is recorded before anything trusts `S3UploadTransport`.

1. `ListParts` for a `(key, uploadId)` pair whose `uploadId` belongs to a different key
   returns `NoSuchUpload`. **If it returns an empty part list instead**, §5's table loses the
   row that answers "does this uploadId belong to this key?" without a store, and ADR-0001
   O-2 reopens.
2. `CompleteMultipartUpload` accepts the `(PartNumber, ETag)` list exactly as `ListParts`
   returned it, quoting included. **If a transformation is needed**,
   `cloud/handlers/complete.ts` is wrong.
3. `CreateMultipartUpload` returns a non-empty opaque `UploadId`. **If it can be empty**,
   `openSession` can legitimately mint `ref + "/"`, so an empty uploadId stops being malformed
   and §2's list of three drops to two — the parse would then be refusing a string this
   transport really did mint.
4. A presigned PUT signed for one part number and one uploadId is refused for any other.
   **If it is not**, the URL is not as narrow as claim 2 says and claim 2 must be reworded.

### 5. ADR-0001 O-2 closes: no database

O-2 asked where the server-side upload record lives, and set the condition for answering it:
whether the control plane needs application-level queries, ownership records, idempotency
state or lifecycle tracking that S3 cannot serve efficiently. The four routes in §4 are now
written down, so the questions the control plane must answer can be enumerated rather than
estimated.

| Question the control plane must answer | What serves it | Needs a store? |
|---|---|---|
| May this caller upload here? | the verified `sub`, prefixed | no |
| What is the key for this request? | `uploads/<sub>/<ref>`, derived | no |
| Does this uploadId belong to this key? | S3 `ListParts` — a mismatched pair returns `NoSuchUpload` | no |
| Which parts does the authority hold? | S3 `ListParts` | no |
| What is the key, given only an uploadId? | the composed identity in §2 carries it — otherwise a `ListMultipartUploads` scan under the caller's prefix | no, because of §2 |
| Which uploads has this user in flight? | `ListMultipartUploads` under the prefix, O(n in-flight) | no today |
| Is this create request a retry of one already served? | nothing here serves it | **this one would** |

Read the last two rows together. Without §2's composition, every `confirmedProgress` and
every `finalize` becomes a prefix scan to recover a key the client already knew — an O(n)
list on the hot path, growing with a user's in-flight uploads, and *that* is what makes an
index look necessary. With it, S3's own enumeration answers every question the control plane
must answer to serve the four routes.

**O-2 closes: no database.**

The honest remainder is the idempotency row. A `POST /uploads` retried after its response is
lost creates a second multipart operation, and nothing in S3 dedupes it. That is exactly
ADR-0005 O-8: an orphaned operation costs storage at the authority and not correctness,
because no confirmed chunk is re-sent — the second operation simply has nothing confirmed in
it. It is already open, already accepted as a storage cost, and §7's lifecycle rule bounds
it. If it ever has to be *prevented* rather than bounded, that is the demonstrated need, and
O-2 reopens with a reason rather than a hunch.

### 6. Teardown is two steps, and the first one is not `cdk destroy`

`autoDeleteObjects: true` does not abort in-progress multipart uploads. This was read rather
than assumed. At `aws-cdk-lib` **2.267.0**, the vendored custom-resource handler at

```
node_modules/aws-cdk-lib/custom-resource-handlers/dist/aws-s3/auto-delete-objects-handler/index.js
```

was read in full on 2026-08-29. Its Delete path calls exactly five S3 APIs:
`getBucketTagging` (it skips unless the bucket carries `aws-cdk:auto-delete-objects=true`),
`getBucketPolicy`, `putBucketPolicy` — adding a `Deny` on `s3:PutObject` for
`Principal: "*"` — then `listObjectVersions` in a loop while truncated, and `deleteObjects`
over versions and delete markers. There is no `listMultipartUploads` and no
`abortMultipartUpload`. Parts already uploaded are not objects, and `listObjectVersions`
never enumerates them.

The deny it adds is worth reading carefully, because it looks like it might do the job and
does not. `s3:PutObject` is the permission `CreateMultipartUpload`, `UploadPart` and
`CompleteMultipartUpload` all require, so the deny stops *new* part uploads. It does not
abort the operations that already exist.

So the procedure is two steps:

```
# 1. abort every multipart upload still in progress
aws s3api list-multipart-uploads --bucket <name>
aws s3api abort-multipart-upload --bucket <name> --key <key> --upload-id <id>   # once per upload

# 2. destroy the stack
cd cloud && npx cdk destroy Dunnage
```

This is not one command, and no document that describes it may say that it is. It is in an
ADR rather than a runbook because a learning
account with orphaned resources is how a free tier becomes a bill, and because step 1 is the
step a reader would otherwise not know exists.

**`s3:AbortMultipartUpload` is granted to no role in this stack.** Step 1 is an operator
action taken with the account's own credentials, not an endpoint. No route in §4 aborts, and
a permission held for an operation that does not exist is the speculative kind the
architecture rules refuse. It arrives with the endpoint that needs it, if one ever does.

**This section is a precondition on 4b, not a note for later.** 4b creates the bucket that
can hold an orphaned multipart upload. It must not deploy one before the procedure that
removes it is written down — which is why this document is the first commit of the phase and
not its last.

Two things are UNVERIFIED here and are recorded rather than guessed away:

- **That `DeleteBucket` fails while incomplete multipart uploads exist.** This is documented
  AWS behaviour. No account was touched, so it was not executed. The two-step teardown is
  correct under either answer, which is why this is recorded rather than chased.
- **The IAM actions CDK grants the auto-delete provider's role.** They are not literals in
  the vendored JavaScript and were not located from source. They become visible in the
  synthesised template at the first synth, and claim 5's
  `testListMultipartUploadPartsAppearsInNoOtherRole` reads that role anyway.

Two further statements above are about S3 rather than about the handler: that
`listObjectVersions` does not enumerate uploaded parts, and that `s3:PutObject` is the
permission the three multipart writes require. Both are documented AWS behaviour and neither
was executed here. Neither is load-bearing either — the procedure rests on the handler calling
no multipart API at all, which the file read does establish.

### 7. Seven days is ADR-0005 O-10's exposure, with a number on it

The bucket carries `abortIncompleteMultipartUploadAfter: Duration.days(7)`.

It bounds §5's honest remainder and ADR-0005 O-8's orphan: an operation nobody will complete
stops costing anything after a week, without anybody having to notice it.

It also *produces* ADR-0005 O-10, on a schedule. An operation the lifecycle rule has aborted
is an authority that has forgotten it: `confirmedProgress` throws `.unknownSession`, the
driver appends nothing and stops (ADR-0005 §8), and the upload is unable to move rather than
failed. The exposure now has a size — **seven days** — and a cause that is this project's own
configuration rather than an outage.

UNVERIFIED: that the window is measured from the initiation of the multipart operation
rather than from the last part uploaded. That is the documented meaning of the rendered
lifecycle rule, and it makes the window a bound on the life of the operation and not on its
idle time — an upload still making progress after seven days is aborted too. No account was
touched, so it was not executed.

4a states the exposure and its size. **4b decides the recovery**, because recovering means
opening a second transport operation for an upload that already has one — a new event, a new
row in the transition table, and a decision about what confirmed progress from a dead
operation means. ADR-0001 §2 refused that decision until there was a demonstrated need. This
is the need; the transport that meets it is 4b's.

### 8. What this stack may not later do

Claim 1 — *the stack synthesises with no account, no region and no credential, and nothing
it does can quietly acquire one* — is what makes this phase checkable by a reader who is not
the author. Claims 2 and 5 are read off a synthesised template, and a template a reader
cannot produce is a claim only the author can check. It is also the claim that fails quietly:
4b adds resources to this stack, and each of the four below would make claim 1 false without
a test noticing.

- **No `env` on the stack.** An `env` fixes an account and a region, which is the
  precondition every context lookup needs and the opposite of the property claim 1 states.
- **No `fromLookup`, anywhere.** A context lookup calls AWS during synth. One line in one
  construct turns a credential-free synth into a credential-requiring one.
- **No `NodejsFunction`, and no bundling of any kind during synth.** It bundles at synth time
  with local esbuild when present and Docker when not, which would make the credential-free
  property depend on what happens to be installed on the machine. The handler asset is built
  by `npm run build` before synth and read with `Code.fromAsset`.
- **No `cloud/cdk.context.json`.** The file is a cached answer to a question that needed a
  credential once. Its absence is checked, and that check is a guard rather than a negative
  control: a file-absence assertion demonstrates nothing failing, and this phase's negative
  control is claim 6.

Each is a property of the source rather than of a deployment, so each is checkable by
anyone who clones the repository, which is the whole point of splitting 4a out of phase 4.

### 9. What this supersedes in the 4a design spec

`docs/superpowers/specs/2026-08-29-phase-4a-control-plane-design.md` is committed, it will be
read again, and nothing in it will say it was corrected. An ADR supersedes an ADR by naming
what it replaced; a spec is owed the same.

- **§5 says `handlers/identity.ts` holds two functions. It holds three.** `verifiedSub(event)`
  joins `objectKey` and `validateRef`. It is the code path §5's own claim is about — "`sub`
  comes only from `event.requestContext.authorizer.jwt.claims.sub`" — and that path has to
  live somewhere; four copies in four handlers is four places to get it wrong. It is pure and
  performs no I/O, so §5's characterisation of the file is otherwise unchanged.
- **§12 lists the bucket as out of scope. The template declares one.** "No bucket is created"
  means none exists in AWS, and none does: nothing in 4a deploys. §6's bucket-policy
  assertions, §7's removal policy and lifecycle rule, and §11's `autoDeleteObjects` question
  are all template-level, and each needs the stack to declare a bucket.
- **§8's wording of claim 2 is replaced.** "No principal an end user could hold is granted
  anything on the bucket" reads as a statement about principals, and a presigned URL is not a
  grant to a principal — a five-part upload hands out five of them. The claim becomes: *A
  device holds no principal and no standing grant on the bucket: each authority it does hold
  names one operation on one part, and expires.* That is the wording that reaches `README.md`
  and `docs/invariants.md`.
- **§7's one-command teardown is replaced by §6 above.** §11 named the condition under which
  it would be wrong; the read of the vendored handler in §6 found that it is.
- **Not a supersession, but a slip worth naming:** §3.2's heading reads "Splitting on the
  first separator, and **the two** malformed cases", while its own body says "exactly three
  malformed inputs" and then lists three. Three is right and §2 above agrees with the spec's
  body, so nothing here is decided differently. The heading is named only because a reader who
  stops at it counts wrong.

## What this costs

- **A rule with no compiler behind it.** §2's grammar exclusion is enforced by one TypeScript
  test and by a comment at each of two call sites in two languages. A reviewer is the
  mechanism. That is the price of composing the identity at all, and what it buys out of is a
  `ListMultipartUploads` scan on the hot path of every resume.
- **4a's suite establishes nothing about S3.** §4's four assumptions are unchecked until 4b
  runs against a real bucket. A green 4a is a statement about a synthesised template and
  about pure functions, and about nothing else.
- **Two ways to become unable to move, and no way to say so.** §3's unparseable identity and
  §7's expired operation both end in an upload that is not failed and cannot proceed, with
  nothing on the log and no signal to a user. Both wait on the same 4b decision.
- **Teardown depends on a person.** Step 1 of §6 needs an operator with the account's own
  credentials, and nothing in the stack can perform it, deliberately. A forgotten step 1
  leaves parts accruing storage in a bucket that `cdk destroy` may then refuse to remove.

## The honesty boundary

Nothing in this phase is deployed and no AWS account is touched, so nothing here is evidence
about a running system. `cdk synth` producing a template says the template can be produced
without a credential; it says nothing about whether deploying it would succeed.

§6's finding is a read of a vendored JavaScript file at a pinned version. It establishes what
that handler calls, and nothing more. Every statement in §6 about what S3 itself does — the
two named at the end of that section, and the `DeleteBucket` question — is documented AWS
behaviour rather than behaviour executed here, because no account was touched. The same is
true of §7's window. None of them is load-bearing, which is why they are disclaimed rather
than chased: the two-step procedure and the seven-day exposure are both right whatever the
answers turn out to be.

## Deliberately not decided

- **No abort endpoint, and no `s3:AbortMultipartUpload` anywhere in the stack.** §6 makes the
  abort an operator action. An endpoint would need a route, a permission and a decision about
  who may abort whose upload, and nothing has asked for one.
- **Which `TransportError` a malformed session identity throws.** A new case or
  `.unknownSession` is a change to Core, and the transport that demonstrates the need is 4b's
  (§3).
- **No idempotency state, so a lost `POST /uploads` response costs one orphaned operation.**
  Bounded by §7 and not prevented. Preventing it is the demonstrated need that reopens O-2.
- **No recovery from an operation the authority no longer has.** ADR-0005 O-10 stands. §7
  gives its exposure a size; it does not close it.

## Open questions

### O-12. Nothing on the log says where a payload's bytes come from

`UploadIntent` carries the upload identity, the destination, the chunk plan and the retry
policy. Nothing in it, nothing in `UploadEvent.declared`, and nothing anywhere on the ledger
names the file the bytes are read from. `UploadTransport.send` receives a `PlannedTransfer` —
a `ChunkID` and a `ByteRange` — and no source.

`InMemoryTransportDouble` never noticed, because it synthesises the bytes it is asked for. A
transport that has to open a real file cannot.

This collides with a phase-1 claim already in `README.md` and `docs/invariants.md`: *state
comes only from replaying the log, and a cold start finds everything it needs there.* The log
alone cannot locate the file, so for any transport that must open one, the claim is false as
written. Phases 1 to 3 did not expose it because nothing in them opened a file.

It is closed in 4b by a `PayloadRef` on `UploadIntent`, opaque to Core the way
`DestinationRef` is. That is a change to a Core type the ledger writes, so it bumps
`LedgerFormat.version` from 1 to 2 — the second version ADR-0004 said would need a reader
that has seen two. Whether that reader is written, or a version-1 log is simply refused under
ADR-0004 §4, is 4b's to decide with the change.
