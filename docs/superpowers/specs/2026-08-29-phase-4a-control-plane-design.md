# Phase 4a — the control plane, and the half a reader can check without an account

- **Status:** design, approved for planning
- **Date:** 2026-08-29
- **Scope:** a `cloud/` CDK application, its Lambda handlers, template assertions, and the
  CI that runs all three on a machine with no credentials. No bucket is created. No AWS
  account is touched.
- **Leaves to 4b:** the bucket, the presigned URLs against a real service, the
  `S3UploadTransport` that satisfies `UploadTransport`, the recorded contract run, the
  `PayloadRef` change to Core, and the recovery ADR-0005 O-10 needs.

## Why 4a exists as its own phase

README row 4 makes four claims:

```
1  the bound holds against a real transport
2  the device never holds an AWS credential
3  the server derives object ownership from the authenticated principal
4  cdk synth runs with no cloud credentials
```

Claim 4 gates the other three: if it does not hold, nothing in this phase is checkable by
anyone who is not the author. Claims 2, 3 and 4 are assertions about a file and about pure
functions. They need no cloud at all, so they go in CI and a reader can run them. Claim 1
needs something that speaks S3, and that is 4b.

One correction to how row 4 has been framed until now. **Claim 3 is not a template claim.**
A template can show that the Lambda's role holds a narrow policy; it cannot show that the
handler builds the object key from the verified `sub` rather than from the request body.
That half is a unit test on a pure function, and it is where the content of claim 3 lives.
The template half is real but weaker.

## 1. Layout

```
cloud/                        npm project. SPM does not look here.
  bin/dunnage.ts              the app — environment-agnostic, no context lookups
  lib/stack.ts                the stack
  handlers/identity.ts        pure: objectKey(sub, ref), validateRef(ref)
  handlers/create.ts          POST   /uploads
  handlers/urls.ts            POST   /uploads/{ref}/urls
  handlers/parts.ts           GET    /uploads/{ref}/parts
  handlers/complete.ts        POST   /uploads/{ref}/complete
  test/template.test.ts       aws-cdk-lib/assertions
  test/identity.test.ts       the pure functions
  dist/handlers/              built asset. gitignored.
  package.json  cdk.json  tsconfig.json
```

`aws-cdk-lib` 2.267.0 exports `./aws-apigatewayv2-authorizers` as stable; the alpha package
stopped at 2.114.1-alpha.0 and is not a dependency here.

## 2. The API the transport will speak

```
POST   /uploads              {ref, parts}      CreateMultipartUpload      -> openSession
POST   /uploads/{ref}/urls   {uploadId,parts}  presigned PUT per part     -> send
GET    /uploads/{ref}/parts  ?uploadId=        ListParts                  -> confirmedProgress
POST   /uploads/{ref}/complete {uploadId}      ListParts + Complete       -> finalize
```

`finalize` is a control-plane call, not a device call. `CompleteMultipartUpload` requires
the caller to hand back the `(PartNumber, ETag)` list, and the device retains no ETags —
inventing an ETag ledger on the device would contradict ADR-0001's `ETag ≠ application
content hash`. So the Lambda calls `ListParts` and completes from what S3 itself reports.
Two consequences worth naming: `s3:ListMultipartUploadParts` stays in the control plane,
which is what `docs/architecture/aws.md` already decided, and the device cannot complete an
object over parts it never sent.

## 3. The composed session identity

### 3.1 The composition, and the rule it depends on

`TransportSessionID` is opaque to Core — never parsed, never compared structurally. The
transport therefore composes its own identity out of the two things the server needs:

```
TransportSessionID.rawValue  ==  "<destinationRef>" + "/" + "<s3UploadId>"
```

This exists because of a gap that is only visible at a cold start. After a process death
the driver replays the log, recovers the session id from `transportSessionOpened`, and
calls `confirmedProgress(in: session)`. The transport receives the session id **and nothing
else** — not the intent, so not the `DestinationRef`. Without composing them, the transport
cannot name the key, and the server cannot answer.

**The parse is total only because a `DestinationRef` cannot contain the separator, and what
keeps that true is §5's refusal test — `testARefContainingASeparatorIsRefused`.**

The two halves are further apart than "two files." The server never sees the composed
string: the transport splits it and sends `ref` in the path and `uploadId` in the body, so
`parseSession` is Swift and lands in 4b, while `validateRef` is TypeScript and lands here in
4a. The rule and the parse that depends on it are in different languages, in different
suites, in different phases. Nothing a compiler or a test runner sees connects them.

That is why the coupling is written into ADR-0006 rather than left to a comment: relaxing
the ref grammar to admit a separator makes a Swift function ambiguous, silently, from a
TypeScript file, and the only surviving guard would be a test whose name does not mention
the parse. It is stated in the ADR at the definition of the composition, and repeated as a
comment at both call sites when each is written. It is not stated only next to the regex.

### 3.2 Splitting on the first separator, and the two malformed cases

`parseSession` splits on the **first** separator: everything before it is the ref,
everything after it is the uploadId, whatever it contains.

An identifier with two separators is therefore **not** a malformed case. It is an uploadId
that contains a separator, and it parses correctly. S3's multipart upload id is an opaque
token and this design refuses to assume anything about its grammar; splitting on the last
separator, or rejecting a second one, would encode a guess about a vendor's format that S3
has never promised.

That leaves exactly three malformed inputs: no separator at all, an empty ref, an empty
uploadId. All three mean the same thing — **this string is not a session identity this
transport ever minted.** `openSession` is the only place one is created, and it always
creates a well-formed one.

The behaviour is decided here and implemented in 4b, with `parseSession`.

### 3.3 Why this is not answered the way ADR-0004 §4 answered its question

The identifier comes off the log, so the question looks like ADR-0004 §4: a record this
binary cannot interpret refuses the whole replay rather than being skipped or guessed at.
It is decided differently, and the difference is the reason ADR-0004 gave for its own
answer.

ADR-0004 refuses a replay because an undecodable record poisons the fold. Every later event
is folded against a history missing a step, so the derived state "is wrong and looks fine."
Refusing derives nothing, which is worse for availability and better for the invariant, and
that trade is taken because the failure is visible.

A session identity that does not parse poisons nothing. The ledger decoded it correctly —
it is a `String`, and Core neither reads nor compares it. The replay is exact, the derived
state is right, the retry tally is right, and every other upload on the log is unaffected.
The only thing that cannot proceed is the next transport call for this one upload. Refusing
the whole replay would discard correct state to punish a string that exactly one component
in the system understands.

So: **the transport refuses the call, and nothing else.** It throws at the boundary. Per
ADR-0005 §8 the driver appends nothing and stops, and the upload is unable to move — which
is the same shape as ADR-0005 O-10, an authority that has forgotten the operation. Both
wait on the same 4b decision about replacing a transport operation, and neither is a
failure. That the two land in one place is a property of the design, not a coincidence.

Whether this needs a new `TransportError` case or reuses `.unknownSession` is a 4b
question, because it is a Core change and the transport that demonstrates the need does not
exist yet. 4a records that the case exists and what it must not do.

### 3.4 What the control plane must answer, and what serves each

This is the argument that ADR-0001 O-2 stays closed. The composition is not an aside in it;
it is the half that removes the scan, and the scan is the thing that would eventually want
an index.

| Question the control plane must answer | What serves it | Needs a store? |
|---|---|---|
| May this caller upload here? | the verified `sub`, prefixed | no |
| What is the key for this request? | `uploads/<sub>/<ref>`, derived | no |
| Does this uploadId belong to this key? | S3 `ListParts` — a mismatched pair returns `NoSuchUpload` | no |
| Which parts does the authority hold? | S3 `ListParts` | no |
| What is the key, given only an uploadId? | **the composed identity carries it** — otherwise a `ListMultipartUploads` scan under the caller's prefix | no, because of §3.1 |
| Which uploads has this user in flight? | `ListMultipartUploads` under the prefix, O(n in-flight) | no today |
| Is this create request a retry of one already served? | nothing here serves it | **this one would** |

Read the last two rows together. Without the composition, every `confirmedProgress` and
every `finalize` becomes a prefix scan to recover a key the client already knew — an O(n)
list on the hot path, growing with a user's in-flight uploads, and *that* is what makes an
index look necessary. With it, S3's own enumeration answers every question the control
plane actually asks, and no database is introduced.

The honest remainder is the idempotency row. A `POST /uploads` that is retried after the
response is lost creates a second multipart operation, and nothing in S3 dedupes it. That
is exactly ADR-0005 O-8 — an orphaned operation costs storage at the authority, not
correctness, because no confirmed chunk is re-sent. It is already open, already accepted as
a storage cost, and the lifecycle rule in §7 bounds it. If it ever needs to be *prevented*
rather than bounded, that is the demonstrated need for a store, and O-2 gets reopened with
a reason rather than a hunch.

**O-2 closes: no database.**

## 4. Synth must not be able to quietly acquire a credential

Four properties.

- the stack sets no `env`, so it is environment-agnostic
- no `fromLookup` anywhere; the CLI runs `--no-lookups`
- **no bundling during synth.** `lambda.Function` with `Code.fromAsset('dist/handlers')`,
  built by an `npm run build` that runs before synth. Not `NodejsFunction`: it bundles at
  synth time with local esbuild when present and Docker when not, which makes the
  credential-free property depend on what happens to be installed on the machine
- `cloud/cdk.context.json` does not exist, and a check fails if it appears

`@aws-sdk/s3-request-presigner` is a separate package that the managed Node runtime does not
ship, so the asset bundles its dependencies rather than relying on what the runtime happens
to include. Bundling happens in `npm run build`, never in `cdk synth`.

**The context-file check is a guard against a synth that needed a credential once and cached
the answer.** It is not a negative control. A negative control in this repository is the
failure mode the thesis removes, kept working on purpose — phase 1 resends every byte,
phase 2 skips bytes nobody confirmed, phase 3 abandons an upload nothing refused. A
file-absence assertion demonstrates nothing failing. 4a's negative control is claim 6 in
§8, and that word is reserved for it.

CI runs synth with the AWS environment explicitly scrubbed rather than merely absent, so a
runner that later gains OIDC credentials does not silently start passing for a different
reason. The development machine for this phase has no `aws` binary, no `~/.aws`, and no
`AWS_*` set, so every property above is checkable here before it reaches CI.

## 5. The half that is a pure function

`handlers/identity.ts` holds two functions with no I/O in them. `parseSession` is not
among them — the server never receives a composed identity, and §3.1 says where it lives.

```ts
objectKey(sub: string, ref: string): string      // `uploads/${sub}/${ref}`
validateRef(ref: string): boolean                // ^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$
```

`sub` comes only from `event.requestContext.authorizer.jwt.claims.sub`. There is no code
path by which a request body reaches the key.

- a body carrying `key`, `sub` or `userId` produces the **same** key as a body without them
- a missing `sub` claim is a 401, never a default and never an empty prefix
- a ref that fails the grammar is a 400. `../`, `%2e%2e`, `/`, a leading `.`, an empty
  string and a 65-character ref are **refused, not repaired**. Sanitising is wrong on its
  own terms: it maps two distinct refs onto one key, so two uploads become one object
- a presigned URL is scoped to one method, one key, one part number, one uploadId, and a
  short expiry

The presigner signs offline, so the URL tests need no cloud. They do need credentials inside
the signer, and those are obviously-fake non-`AKIA`-shaped placeholders — `test-access-key-id`
— not AWS's published example keys. Nothing key-shaped enters the repository, a diff, or a
secret scanner's output.

## 6. What the template must not contain

Cognito **user pool** only, and no identity pool. There is then no role a device could
assume, which is a stronger claim than a narrow one. The device obtains a JWT from Cognito
directly, using the app client id, and holds no AWS credential at any point.

- `resourceCountIs('AWS::Cognito::IdentityPool', 0)`
- every `AWS::IAM::Role` is assumable by AWS services only — no `Federated` principal, no
  `AWS:` principal
- every **Allow** statement in the bucket policy names a role defined in this stack. Stated
  about Allow specifically: `enforceSSL` adds a `Deny` on `Principal: *`, and a blanket "no
  `*`" assertion would either fail on that or be loosened until it asserts nothing
- the Lambda role holds `s3:PutObject` and `s3:ListMultipartUploadParts` on
  `<bucket>/uploads/*` — not `s3:*`, not `<bucket>/*`. `s3:AbortMultipartUpload` is **not**
  granted: no endpoint in §2 aborts, and a permission held for an operation that does not
  exist is the speculative kind the repository's architecture rules refuse. It arrives with
  the endpoint that needs it
- `s3:ListMultipartUploadParts` appears in no other role in the template

## 7. Naming and teardown

One stack, `Dunnage`. Every resource tagged `Project=Dunnage`. Bucket physical name left to
CDK, so no globally-unique name is committed and no collision is inherited. Bucket
`removalPolicy: DESTROY` with `autoDeleteObjects: true`; user pool `removalPolicy: DESTROY`.

Teardown is `cd cloud && npx cdk destroy Dunnage`, and that is the whole procedure. It is in
the ADR because a learning account with orphaned resources is how a free tier becomes a bill.

`abortIncompleteMultipartUploadAfter: Duration.days(7)`. That window is ADR-0005 O-10 made
concrete: an operation the lifecycle rule has aborted is an authority that has forgotten it,
and the upload is unable to move. **4a states the exposure and its size. 4b decides the
recovery**, because recovering means opening a second transport operation for an upload that
already has one — a new event, a new row in the transition table, and a decision about what
confirmed progress from a dead operation means. It belongs with the transport that
demonstrates the need.

## 8. The six claims

Ordered as they will appear in `README.md` and `docs/invariants.md`.

1. The stack synthesises with no account, no region and no credential, and nothing it does can quietly acquire one
2. No principal an end user could hold is granted anything on the bucket
3. The object key is derived from the authenticated principal, and a field the client sends never reaches it
4. A reference the caller supplies names a leaf inside its own prefix or it is refused, never repaired
5. The control plane holds the only credential, and the only enumeration permission
6. The failure mode a client-trusted key reintroduces, kept working on purpose

Claim 6 is the negative control: a handler that derives the key from the request body,
kept working, with a test showing two callers landing on one object.

Claims 3, 4 and 6 go red first, genuinely. Parts of 2 and 5 are structural assertions that
pass the moment the resource exists and cannot go red without sabotaging the stack; per the
repository's own rule those carry a one-line note in the commit rather than a manufactured
failure.

## 9. CI

A third job. The two existing ones are deliberately single-purpose, and the
name-reconciliation guard now has to see two runners' test lists on two machines.

```
build-and-test (macos-26)      swift build && swift test
                               -> uploads the swift test-name list
cloud-stack (ubuntu-24.04)     npm ci && npm test && cdk synth, environment scrubbed
                               -> uploads the vitest test-name list
docs-agree (ubuntu-24.04)      needs both. one diff against docs/invariants.md,
                               and check 4a 6
commit-message-hygiene         unchanged
```

TS tests keep the `testXxx` naming convention, so the union of both runners is one list and
the guard stays a single statement in both directions — every name in the doc is a real
test, and every real test is in the doc — rather than two half-guards that each read only
their own side.

Moving the existing claims guard out of `build-and-test` is a mechanical change and its own
commit.

## 10. ADR-0006, and the ADR edits this phase owes

ADR-0006 records: O-2 closed as no database, with §3.4's enumeration as the demonstration;
`finalize` in the control plane and why the device keeps no ETag ledger; the composed
session identity and the grammar rule it depends on; `ETag ≠ application content hash`
restated where a real service touches it; teardown; and the lifecycle window as O-10's
exposure.

**ADR-0001 O-3 closes.** Its stated trigger — "before this document is quoted externally" —
has fired, because the repository is public and phase 4 is the first phase whose correctness
costs anything if the citation is wrong. Checked on 2026-08-29 against the IETF datatracker:
`draft-ietf-httpbis-resumable-upload` is **not** an RFC. It is an active Internet-Draft,
latest revision -12 dated 2026-07-06, IESG state "I-D Exists", intended status Proposed
Standard. ADR-0001's citation is therefore correct as written. O-3 closes with the answer
and its date rather than being carried as UNVERIFIED past its own trigger.

**New: O-12** — the payload-source gap. Nothing in Core, in `UploadEvent.declared`, or on
the ledger names where a payload's bytes come from; `UploadTransport.send` receives a
`ChunkID` and a `ByteRange` and no source. `InMemoryTransportDouble` never noticed because
it synthesises them. This collides with a phase-1 claim already in the README — *a cold
start finds everything it needs there* — since the log alone cannot locate the file. Closed
in 4b by a `PayloadRef` on `UploadIntent`, opaque to Core like `DestinationRef`, which bumps
`LedgerFormat.version` from 1 to 2.

## 11. Open at the time of writing

Neither of these is an ADR open question. They are implementation unknowns that resolve on
the first synth, and they are recorded here so this document reads as it was written. If an
answer turns out to constrain a later phase, it gets promoted to ADR-0006.

- **Does `HttpJwtAuthorizer`'s `jwtIssuer` accept the region token from
  `userPool.userPoolProviderUrl` in an environment-agnostic stack?** The issuer URL contains
  the region, which is an unresolved token until deploy. It should render as an `Fn::Join`
  in the template. Not verified.
- **Does `autoDeleteObjects` empty a bucket that has in-progress multipart uploads?** S3
  refuses to delete a bucket while incomplete multipart uploads exist, and whether CDK's
  auto-delete custom resource aborts them or only deletes objects is not verified. If it
  does not, §7's one-command teardown is not one command, and the answer is either an abort
  endpoint or a documented second step. This is a real risk for a learning account, so it is
  checked before 4b creates anything.
- **Is `--no-lookups` sufficient on its own?** Whether `cdk synth` also needs `CDK_DEFAULT_ACCOUNT`
  and `CDK_DEFAULT_REGION` unset, or objects to a missing region for other reasons, is not
  verified. The environment-scrubbing step in §9 is written to be sufficient either way, but
  which parts of it are load-bearing is unknown.

## 12. Out of scope

The bucket. Presigned URLs against a real service. `S3UploadTransport`. The recorded contract
run. `PayloadRef` and the ledger format bump. O-10's recovery. Background `URLSession` and
lifecycle events, which are phase 5. The app. Anything requiring an AWS Organization or
Control Tower — either would expire the account's credits immediately, and nothing here
needs one.
