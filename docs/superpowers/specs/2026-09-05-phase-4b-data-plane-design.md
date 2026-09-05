# Phase 4b — the data plane, and the account this repository never names

- **Status:** design, awaiting review
- **Date:** 2026-09-05
- **Scope:** ADR-0005 O-10's recovery, decided in Core and the driver and needing no cloud;
  a new event, a new rejection reason and a new written form on the ledger; the plane
  rendering an operation the authority has forgotten as something a device can read; the
  stack's outputs and the one flow that mints a token; a contract run against a deployed
  stack and real S3, gated on a file this repository does not have; `docs/deploy.md`; and
  one recorded run whose findings are written into ADR-0006 and ADR-0007 and never into
  CI. ADR-0009 and ADR-0010.
- **Leaves to nobody:** this is the last planned phase. What it does not close it names as
  an open question rather than passing on.
- **Supersedes:** ADR-0005 §8's sentence that a thrown transport error becomes no event,
  in exactly the two cases §2 below names; ADR-0005 O-10, which closes; ADR-0006 §7's
  "4b decides the recovery" and its "Deliberately not decided" bullet on recovery;
  ADR-0007's cost "Two ways to be unable to move remain" and its "Deliberately not
  decided" bullet on what the plane renders for `NoSuchUpload`. Each is named by ADR-0009
  or ADR-0010, in the commit that makes it false.

Every decision marked **[stated]** is the author's answer in the brainstorm that produced
this document, recorded as given. Everything else follows from those answers, and the plan
may not weaken a stated one.

## Why 4b is two halves, and why only one of them needs an account

4a split phase 4 so that a reader with no AWS account could check the half that is a file
and a pure function. 4b inherits the other half and splits again, on the same line.

**The pure half is O-10's recovery.** An authority that has forgotten a transport
operation leaves an upload that is not failed and cannot move (ADR-0005 O-10), and
ADR-0006 §7 gave that exposure a size — seven days — and assigned the recovery here. It is
a change to the transition table, the ledger's alphabet and the driver's reading of a
thrown error. It touches no network, needs no bucket, and is checked by `swift test` on a
machine with no credential of any kind. **It is done first**, and it is the only work in
this phase that CI can hold.

**The other half is one run.** The six falsifiers ADR-0006 §4 wrote down and the three
assumptions ADR-0007 §9 recorded are questions about S3 and about a deployed plane. No
suite in this repository can answer them, and none may pretend to: what answers them is an
operator deploying the stack into an account, asking S3 the nine questions, writing the
answers down, and destroying the stack. That is the device harness's shape and it takes
the device harness's discipline — a numbered procedure, a Record section per step, and
findings that reach an ADR and never a CI claim.

**[stated] Decision 0.** The tasks are ordered so that every task but the last is finished
and reviewed before any AWS account exists. §11 is that order.

## 1. O-10's recovery: what replaces an operation the authority no longer has

### 1.1 The event, and what it is not

**[stated] Decision 1.** Recovery means opening a second transport operation for an upload
that already has one — the decision ADR-0001 §2 refused until there was a demonstrated
need, and ADR-0006 §7 and ADR-0007 §8 between them supplied two. One new event carries it:

```
case transportSessionLost(TransportSessionID)
```

*The authority no longer has this transport operation.* ADR-0006 §3 fixed what this case
must not be, and this is none of them:

- **not a `TransferOutcome`** — it says nothing about a chunk, and no chunk event is
  written for it;
- **not an interruption** — no transfer was attempted, so nothing about a chunk reaches
  the log;
- **never an abandonment** — giving up is Core's conclusion against a budget (ADR-0003
  §5), and this is not giving up. The upload continues, in a new operation.

It is a fourth thing: an event about the transport operation itself, which the alphabet did
not have because until now an operation was opened and never lost.

It carries the identity it is about, for the reason `Confirmation` carries one. A loss is
evidence about the operation it names and about nothing else, and a stale loss replayed off
the log must not drop an operation opened after it.

### 1.2 The transition rows

```
(.transferring(intent, session, _, _), .transportSessionLost(id))  where id == session
    -> .accepted(.declared(intent: intent), [.openTransportSession(intent)])

(.finalizing(intent, session, _, _),   .transportSessionLost(id))  where id == session
    -> .accepted(.declared(intent: intent), [.openTransportSession(intent)])

(.transferring, .transportSessionLost)  where id != session  -> .rejected(.lossNamesAnotherTransportSession)
(.finalizing,   .transportSessionLost)  where id != session  -> .rejected(.lossNamesAnotherTransportSession)
(.undeclared,   .transportSessionLost)                       -> .rejected(.uploadNotDeclared)
(.declared,     .transportSessionLost)                       -> .rejected(.noTransportSession)
(.completed, _), (.failed, _)                                -> .rejected(.terminalPhaseIsAbsorbing)
```

`.declared` and not a new phase. After a loss the intent is on record and no transport
operation is open, which is exactly what `.declared` already means, and the row
`(.declared, .transportSessionOpened)` already does the rest: it enters `.transferring`
with `confirmed: nil` and asks the authority before anything is sent. Nothing about the
replacement needs a state the machine did not have.

`.declared(intent:)` carries neither a confirmation nor a tally, so choosing it as this
row's target and §1.3's "the replacement inherits nothing" are one decision and not two —
carrying the tally across would need a new phase, not a different row.

`RejectionReason` gains one case, `.lossNamesAnotherTransportSession`, worded after
`.confirmationFromAnotherTransportSession` because it is the same discipline.

**The totality test does not gain a name.** `UploadEventKind` gains a case, the compiler
makes every phase's row a requirement, and `testTransitionTableIsTotal_EveryStateEventPairHasAnExplicitOutcome`
enumerates kinds, so the new pairs appear in it without a new test. Under the repository's
red-before-green rule this is the compiler-enforced case: the one-line reason is recorded in
the commit and no failure is manufactured.

### 1.3 The replacement inherits nothing, and that is the same rule as everywhere else

Both the confirmation and the attempt tally are dropped by the row above. Neither is an
economy; each is ADR-0001 §2 applied to a different field.

**The confirmation.** S3 part numbers are scoped to a multipart `uploadId`, so part 3 of a
dead operation and part 3 of its replacement are unrelated facts. Carrying the old
confirmed set into the new operation would schedule nothing for chunks the new authority
does not hold, and the upload would finalize over parts that do not exist. That is §7's
negative control, kept working on purpose.

**The tally.** An attempt is a refusal (ADR-0003), and a refusal collected against an
operation that no longer exists may have been *caused* by its not existing: when the
authority aborts an operation with parts in flight, those PUTs are answered with an error,
each becomes `.refused`, and each charges the budget. Carrying those into the replacement
would punish the new operation for the old one's death, and an upload whose last refusals
were all "this operation is gone" would be abandoned on arrival. Refusals scoped to a dead
operation are not evidence about the live one, for the same reason its confirmations are
not.

The cost of that reading is §9's open question O-18, and it is stated there rather than
hedged here.

### 1.4 What redundant transfer is bounded by after a replacement

Everything the dead operation held is sent again. The thesis is untouched and the reason is
its own clause: *"Redundant transfer is bounded by the set of unconfirmed in-flight chunks,
**under the transport's stated contract**."* Under the replacement's contract nothing is
confirmed, because the authority holds nothing under that `uploadId`, so no chunk this
upload sends has been positively confirmed by the authority it is sending to.

That clause is doing real work here for the first time, and it is written into ADR-0009's
costs and into `docs/invariants.md` so no reader takes phase 1's bound to mean a bound on
bytes across an upload's whole life. It is not a bound on bytes; it is a bound per
operation, and a replacement starts a new one.

The parts the dead operation held keep costing storage until the bucket's seven-day rule
aborts them. That is ADR-0005 O-8's shape with a second cause, and it is recorded against
O-8 rather than given a number of its own.

## 2. The driver: which thrown errors become an event

**[stated] Decision 2.** ADR-0005 §8 says a thrown transport error becomes no event, and
that stands for every error but two.

```
TransportError.unknownSession        the authority has no record of this operation
TransportError.unrecognisedSession   this transport never minted this identity
```

Both are answers about the operation rather than about a chunk, and both strand the upload
the same way (ADR-0007 §8). Thrown from `confirmedProgress` or from `finalize`, each
becomes exactly one event, `transportSessionLost(session)`, appended before the fold, and
the fold asks for a replacement. Every other thrown error still becomes no event, and the
round still stops.

This is a mapping and not a conclusion. The driver already maps a `TransferOutcome` to an
event; it now maps two error cases the same way, and the event says what the transport
said. What it must not do is synthesise a chunk-level fact from an operation-level one, and
it does not: no chunk appears anywhere in the event.

**`send` is left alone.** A send's answer is about a chunk, and a loss discovered while
sending is discovered again by the ask that always precedes the next send — Core's
`.send` effect is only ever produced by settling a confirmation, so an ask has already run
and will run again. Mapping inside `send` would add a second path to the same event for no
case the first path misses.

The argument rests on where exhaustion is decided: `.abandon(.retriesExhausted)` is
produced only by `settle`, an ask precedes every settle, and an ask against a dead
operation throws before `settle` runs — so a dead operation's refused PUTs can charge
chunks and can never exhaust one, and ADR-0009 records that dependency under its costs as
ADR-0003 §1's property doing load-bearing work again.

## 3. The plane must render a forgotten operation as something a device can read

Today `cloud/handlers/parts.ts` and `complete.ts` catch nothing from S3, so `NoSuchUpload`
escapes unhandled and the gateway answers whatever it answers for an unhandled error.
`ControlPlaneWire` reads a 404 as `noSuchUpload` and `BackgroundSessionTransport` turns that
into `TransportError.unknownSession`; it reads a 500 as `unexpectedStatus`, which becomes no
event. **So §1's recovery does not reach the real plane until the plane renders the
refusal**, and that is a coupling this spec names rather than discovers at the account.

**[stated] Decision 3.** The two handlers gain one pure function between them:

```ts
// handlers/identity.ts, beside verifiedSub — the only reading, in one place
export function forgottenOperation(error: unknown): boolean
```

It reads the shape this repository decided to read — an error whose `name` or whose
`Code` is `NoSuchUpload` — and the handlers answer 404 with `{"error":"no such upload"}`
when it is true and rethrow when it is not. Its test hands it objects of that shape and of
others. **That is not a stubbed `S3Client`:** ADR-0006 §4 forbids a double of a vendor's
product, and this function is a double of nothing — it is our own reading, exercised over
our own fixtures.

**UNVERIFIED, and assigned to the run:** that the error the S3 client raises for a
mismatched `(key, uploadId)` carries that name. It is ADR-0006 §4's first falsifier and
ADR-0007 §9's second assumption in one question, and if the run answers otherwise the fix
is one function and one commit. Writing the reading before the run is what makes the run a
check rather than an exploration.

Also settled by the same change: ADR-0007's "Deliberately not decided" bullet on what the
plane renders. The transport's 404 reading stops being provisional against the stand-in and
becomes the plane's, with the stand-in agreeing rather than being the source.

## 4. Identity: who issues the bearer token the plane verifies

**[stated] Decision 4, with the three options and what each costs.**

| Option | What it costs |
|---|---|
| **A small dev issuer, its secret a stack parameter** | `HttpJwtAuthorizer` verifies an OIDC issuer's JWKS and cannot verify an HMAC secret, so this replaces it with a Lambda authorizer — the construct claims 2 and 5 of 4a are asserted against. It adds a secret whose only safe home is a deploy-time parameter, and a hand-written verifier with none of the checks a real one makes. It buys nothing this repository needs. |
| **Cognito** | Already in the template. No new secret, no new construct, no change to any 4a claim. One property is added so that the account's own credentials are the only way to mint a token. Chosen. |
| **A JWKS the operator supplies** | Removes the user pool that three 4a claims read, and replaces it with two deploy-time parameters — an issuer and an audience — so the stack stops describing the identity it verifies. It also makes the recorded run depend on an identity provider this repository cannot describe. It is the right answer for someone deploying behind an existing IdP, and it is named here for them; it is not this run's. |

**The one property added.** `UserPoolClient(this, 'Device', { userPool })` passes no
`authFlows`, and `configureAuthFlows` in `aws-cdk-lib` 2.267.0 returns `undefined` when
`props.authFlows` is absent or empty — read on 2026-09-05 — so the template sets no
`ExplicitAuthFlows` at all and no test in the repository reads one. The client gains

```ts
authFlows: { adminUserPassword: true }
```

which renders `ALLOW_ADMIN_USER_PASSWORD_AUTH` and `ALLOW_REFRESH_TOKEN_AUTH`. That flow
requires the caller to hold AWS credentials for `cognito-idp:AdminInitiateAuth`, so **the
only way to obtain a token for this stack is with the account's own credentials.** No
password flow is open to anyone on the internet, no hosted UI exists, and the pool is not
a login surface. `testTheOnlyAuthFlowIsOneThatNeedsTheAccountsOwnCredentials` asserts the
rendered set exactly, and it is red today because the property is absent.

**The app is unchanged.** `token` stays the one place a token enters, exactly as it is: the
operator mints a token with three CLI calls (§10, step 4) and pastes it into the field. It
is an access token with an hour's life, so a run longer than an hour re-pastes one, and
`docs/deploy.md` says so rather than the app growing a sign-in flow.

**UNVERIFIED, and assigned to the run:** whether the HTTP API JWT authorizer accepts a
Cognito *access* token by matching its `client_id` claim against `jwtAudience`. It is
documented AWS behaviour and no account was touched. The run records which token was
accepted; the ID token, whose `aud` is the client id and which carries the same `sub`, is
the fallback and is named in the procedure so a refusal is a step rather than a surprise.

## 5. Account-agnosticism, by construction and by a test

The stack already declares no `env`, no `fromLookup`, no bucket name and no region
(ADR-0006 §8, and the tests under 4a claim 1). Two things are added.

**Outputs.** Nothing in the template names what a deploy produces, and the procedure needs
four values: the API endpoint, the bucket name, the user pool id and the app client id.
Four `CfnOutput`s carry them. Each is a reference to a resource in this stack and never a
literal, so the template still names no environment, and
`testEveryStackOutputIsAReferenceAndNotALiteral` asserts both halves — that the four exist
by name, and that each value is a reference.

**A scan over the tree.** The phase's whole risk is an operator pasting an endpoint into a
document. `testNoTrackedFileNamesAnAccountAnEndpointAnIdentityOrAKey` walks the tracked
files and reports every match of six shapes, collecting them and asserting over the
collection so one hit never hides the next:

```
an ARN carrying an account      arn:aws:<svc>:<region>:<12 digits>:
an API Gateway endpoint         <10 alphanumerics>.execute-api.<region>.amazonaws.com
a user pool id                  <region>_<9 alphanumerics>
an access key id                (AKIA|ASIA) and 16 uppercase alphanumerics
a JSON web token                eyJ... . eyJ... .
an account number in context    "account", then within twelve characters, twelve digits
```

The last excludes a run of one repeated digit, because `000000000000` in
`cloud/test/support.ts` is a fixture and not an account, in the way `0.0.0.0` is not a
host. Run against the tree at `dbb30f5` on 2026-09-05: **no tracked file matches any of the
six.** So the test is green the day it lands and cannot go red without sabotage; the
one-line reason is recorded in the commit rather than a failure manufactured.

**What it does not establish.** It catches shapes, not secrets. It cannot know the bucket
name CDK generated, and a name pasted in prose would pass it. The discipline is the
operator's, and `docs/deploy.md` carries it: `git status` clean before the run and clean
after, and no name, account, region, endpoint or ARN written into the tree at any point.
`cloud/local.contract.json` joins `App/Local.xcconfig` in `.gitignore` for the same reason,
and CI's cloud-stack job gains the check that it is not committed, beside the app job's
check on `Local.xcconfig`.

## 6. The contract run

### 6.1 Its subject: nine questions, and not one of them an assertion about a suite

ADR-0006 §4's six falsifiers and ADR-0007 §9's three assumptions, each its own named test,
each recording what it observed:

| # | Question | Falsifies |
|---|---|---|
| 1 | `ListParts` for a `(key, uploadId)` pair whose uploadId is under another key | ADR-0006 §4.1, and §3 above |
| 2 | `CompleteMultipartUpload` over the `(PartNumber, ETag)` list exactly as `ListParts` returned it | §4.2 — `complete.ts` |
| 3 | `CreateMultipartUpload` returns a non-empty opaque `UploadId` | §4.3 — `SessionIdentity.parse`'s three cases become two |
| 4 | A presigned PUT signed for one part is refused for another | §4.4 — claim 2's narrowness |
| 5 | A presigned PUT with no hoisted `x-amz-checksum-crc32` is accepted | §4.5 — `partSigningClient` |
| 6 | Two requests composing the same key land on one object | §4.6 — the 4a negative control's own statement |
| 7 | A presigned PUT after its expiry is refused with 403 | ADR-0007 §9.1 |
| 8 | The deployed plane's answer for an uploadId not under the key | ADR-0007 §9.2, and §3 above |
| 9 | A presigned part PUT answers 2xx with an `ETag` header | ADR-0007 §9.3 |

Question 7 signs its own URL with `signPartUrl` from `handlers/urls.ts` — the plane's own
signer, at an expiry of one second, with the operator's credentials rather than the Lambda
role's. The difference is named in the record: it is the same signing code and a different
principal, and a run that waits out 900 seconds instead is the operator's to choose and to
write down.

### 6.2 Where it lives, and why its names never reach `docs/invariants.md`

**[stated] Decision 5.** `cloud/contract/`, its own vitest config, its own script, and
never the default suite:

```
cloud/contract/nine.contract.ts       the nine, as named tests
cloud/contract/target.ts              reads cloud/local.contract.json, or reports it is absent
cloud/contract/wrong.ts               an authority that answers each of the nine the other way
cloud/contract.config.mts             include: contract/**/*.contract.ts
package.json  "contract"              vitest run --config contract.config.mts
              "contract:instrument"   the same, against wrong.ts, expected to fail
```

`vitest.config.mts` includes only `test/**/*.test.ts`, so `npx vitest list` — the producer
CI's name guard reads — sees none of the nine. That is deliberate and it is the point:
**a name in `docs/invariants.md` is a claim CI reconciles, and these tests are not run by
CI.** Listing them there would put nine names under a claim beside tests that actually ran,
which is the vacuous green this phase exists to avoid. Their results go where the device
harness's go: an Observed section in the ADR that asked the question.

`testTheDefaultSuiteCollectsNoTestOfTheContractRun` asserts the include globs are disjoint,
so a later edit that widened the default glob would red by name rather than quietly
enlisting nine tests nobody ran.

### 6.3 The gate, and what "not run" has to look like

`cloud/local.contract.json`, gitignored, written by the operator from the stack's outputs:

```json
{ "baseUrl": "...", "bucket": "...", "region": "...", "token": "..." }
```

Absent, `npm run contract` prints a block naming all nine questions and, against each, *not
run — no target*, and **exits 0**. It reports no passes, no skips and no green count. A
skipped test that prints as a pass is the failure mode of every gated suite, and
`testTheContractRunWithNoTargetNamesTheQuestionsItDidNotAsk` is the test that it does not
happen here — it runs in CI, with no target, on every push.

CI never runs the nine. No job holds a credential, and none gains one.

### 6.4 Red before green, without an account

**[stated] Decision 6.** `cloud/contract/wrong.ts` is an authority that answers each of the
nine the other way — a list for a mismatched uploadId, a PUT accepted for the wrong part, an
empty upload id, and so on. `npm run contract:instrument` points the nine at it and expects
to fail. CI runs that as a step in cloud-stack, asserting a non-zero exit and all nine names
in the output, so the evidence that the instrument can fail is produced on every push and
not once in a commit message.

`wrong.ts` is a double of the plane's wire and of nothing else. It answers no question about
S3, it is never the subject of an assertion, and its only job is to make each of the nine go
red once.

### 6.5 LocalStack

**[stated] Decision 7.** LocalStack, in Docker, may be used while the contract runner and
the deploy procedure are being written, for deploy mechanics and for routing. Nothing is
added to `package.json` for it and nothing is committed for it; `docs/deploy.md` names the
two commands in an appendix and says what they are for.

In ADR-0007 §9's own words: **a green run against LocalStack says LocalStack behaves as
assumed, and says nothing about S3.** It is a third party's reimplementation of a vendor's
API, which is further from an observation about S3 than the stand-in is from an observation
about this repository's contract. No answer it gives is written into an Observed section, no
claim rests on it, and no CI step runs it.

## 7. The negative control

**[stated] Decision 8.** The failure mode this phase's recovery removes, kept working:
**a replacement that believes the dead operation's confirmation.**

It lives in `Tests/DunnageTests/`, as phase 1's does — a variant of the transition's loss
row that carries `confirmed` across into the replacement — and its triple keeps the roles
phases 2, 3, 4a and 5 gave it:

- *contract*: the credulous replacement keeps every other rule the real one keeps, and only
  the confirmation's fate differs;
- *control*: after a replacement, `ResumePlan.derive` schedules nothing for the chunks the
  dead operation had confirmed, so the upload finalizes over parts the new authority does
  not hold;
- *contrast*: after the same replacement, the real transition schedules every chunk again.

Pure, deterministic, no clock and no socket. It is never "fixed".

## 8. The claims

Ordered as they will appear in `README.md` and `docs/invariants.md`; `check 4b 6`.

1. An operation the authority no longer has is replaced, and the replacement inherits nothing the operation it replaces was told
2. A loss is evidence about the operation it names, and one naming another operation changes nothing
3. A transport error that is not the authority forgetting still reaches the log as nothing
4. Nothing in the tree names an account, an endpoint, an identity or a key
5. The contract run is gated on a file this repository does not have: without it, it names the questions it did not ask, and it never reports a pass
6. The failure mode a replacement that believes a dead operation's confirmation reintroduces, kept working on purpose

| Claim | Tests |
|---|---|
| 1 | `testAnOperationTheAuthorityNoLongerHasIsReplaced`, `testAReplacementInheritsNeitherTheConfirmationNorTheTallyOfTheOperationItReplaces`, `testALossIsWrittenToTheLedgerAndReadBackAsTheEventThatWasWritten`, `testFinalizingAgainstAnOperationTheAuthorityForgotIsALossAndNotAFailure`, `testTheTransportReadsAForgottenOperationAsUnknownWhenItFinalizesToo`, `testAnOperationTheAuthorityForgotIsRenderedAsARefusalTheTransportReads` |
| 2 | `testALossNamingAnotherTransportOperationChangesNothing` |
| 3 | `testADriverGivenAnAuthorityThatForgotTheOperationRecordsTheLossAndOpensAnother`, `testADriverGivenATransportErrorThatIsNotTheAuthorityForgettingAppendsNothing` |
| 4 | `testNoTrackedFileNamesAnAccountAnEndpointAnIdentityOrAKey`, `testEveryStackOutputIsAReferenceAndNotALiteral`, `testTheOnlyAuthFlowIsOneThatNeedsTheAccountsOwnCredentials` |
| 5 | `testTheContractRunWithNoTargetNamesTheQuestionsItDidNotAsk`, `testTheDefaultSuiteCollectsNoTestOfTheContractRun` |
| 6 | `testACredulousReplacementKeepsEveryOtherRuleTheRealOneKeeps`, `testACredulousReplacementSchedulesNothingForPartsTheNewAuthorityDoesNotHold`, `testTheRealReplacementSchedulesEveryChunkAgain` |

Every test of claims 1, 2, 3 and 6 goes red first, genuinely, and so do
`testTheContractRunWithNoTargetNamesTheQuestionsItDidNotAsk`,
`testTheOnlyAuthFlowIsOneThatNeedsTheAccountsOwnCredentials` — the template sets no
`ExplicitAuthFlows` today — and `testEveryStackOutputIsAReferenceAndNotALiteral`, which
reds because no output exists yet, and which is why it asserts the four by name rather than
only the shape of whatever is there.

Three are structural and carry the one-line reason the repository's rule allows rather than
a manufactured failure: the transition matrix's new pairs, which the compiler requires;
`testNoTrackedFileNamesAnAccountAnEndpointAnIdentityOrAKey`, green against the tree the day
it lands; and `testTheDefaultSuiteCollectsNoTestOfTheContractRun`, which compares two globs.

**The nine contract tests are not on this list and are not claims.** They are observations,
and §10 says where each one's answer is written.

## 9. ADR-0009 and ADR-0010

Two documents, because they are two decisions, and the repository's rule is one decision per
document.

**ADR-0009 — Replacing a transport operation the authority no longer has.** The event and
what it is not; the transition rows and why `.declared`; why the replacement inherits
neither the confirmation nor the tally, and that both follow from ADR-0001 §2; the driver's
two-error mapping and the sentence of ADR-0005 §8 it supersedes; the bound after a
replacement, and the thesis clause that carries it; a costs section; an "Observed against
a deployed plane" section, empty at the first commit, that step 5 of §10 fills; and:

- **ADR-0005 O-10 closes**, with its recovery rather than with its exposure.
- **O-18 opens.** An authority that forgets on a schedule produces open, ask, lose, open,
  for ever, and nothing charges it — a loss is not a refusal and must not become one
  (ADR-0002). It also hands back a fresh budget each time, which is the price §1.3 pays for
  scoping the tally to the operation. This is ADR-0005 O-9's shape with a new cause, and the
  same answer applies: the driver must not invent a stopping rule, and where the decision
  should live is not decided here.
- **ADR-0005 O-8 gains a second cause**, recorded against O-8 and not given a number: a
  replaced operation is an orphan, and the seven-day rule bounds it exactly as it bounds
  the first.

**ADR-0010 — The recorded run, and the account the tree never names.** The identity
decision and its three options; the outputs and the auth flow; the tree scan and what it
does not establish; the contract run's gate, its separate suite, and why its names never
reach `docs/invariants.md`; LocalStack's status in ADR-0007 §9's words; and an Observed
section the run fills. Two UNVERIFIED statements are recorded rather than guessed: the
authorizer's reading of a Cognito access token's `client_id` (§4), and the shape of the
error S3 raises for a mismatched `(key, uploadId)` (§3).

`docs/adr/README.md` gains both, titles matching their H1s.

## 10. `docs/deploy.md`

`docs/device-harness.md`'s form, exactly: what the document does not claim; where a record
goes, with one template copied in filled; a Setup section; then numbered steps, each with
**Purpose**, **Do**, **Record**, and **What this step does not establish**.

```
Setup      credentials the operator already has, and no key in the tree; the region comes
           from the environment; git status clean, and clean again at the end
Step 1     bootstrap                       cdk bootstrap, once per account and region
Step 2     deploy                          npm run build && npx cdk deploy Dunnage
Step 3     the outputs                     read the four into cloud/local.contract.json,
                                           gitignored, and into nothing else
Step 4     a token                         admin-create-user, admin-set-user-password
                                           --permanent, admin-initiate-auth; the access
                                           token, and the ID token if the first is refused
Step 5     the app against the real plane   the simulator, base URL and token typed in,
                                           one upload end to end; then an operation the
                                           authority forgot, aborted by hand, and the
                                           replacement read off the screen
Step 6     the nine questions              npm run contract
Step 7     teardown                        ADR-0006 §6's two steps, in that order
Step 8     idle                            keys disabled, and the target file deleted
```

Three things the document states outright:

- **What it records and where.** Questions 1 to 6 are ADR-0006's, and their answers go into
  an "Observed against S3" section this phase adds to ADR-0006. Questions 7 to 9 are
  ADR-0007 §9's, and their answers go beside those items in an "Observed against S3" section
  this phase adds to ADR-0007. Step 5's replacement — an operation aborted by hand, and what the
  next process did — goes into ADR-0009's Observed section, and the identity and authorizer
  readings into ADR-0010's. A run recorded only in the phase ledger is a run this repository does
  not have, because the ledger is workspace and is not in the tree.
- **What is never written into the tree.** No name, employer, account id, region, endpoint,
  ARN, bucket name, user pool id, client id, password or token. The model of a finding is
  the answer to the question, never the identifier it was observed on.
- **A run that falsifies a claim is still a record.** If the run shows a falsifier answered
  the other way, the code it falsifies is named, the record is written with the same
  template, and neither the ADR sentence nor this spec is softened to make the run fit. The
  device harness's rule, unchanged.

Step 5 is the one place the transport meets the real plane, and it is what row 4b has always
meant by "the same transport": the same code with a different base URL and a different
bearer token, and nothing else (ADR-0007 §1). The simulator and not a device, so the run
needs no team, no profile and no Apple account; the device is the harness's business and
stays there.

## 11. The order of the work

**[stated] Decision 0, made concrete.** Nothing before commit 11 needs an AWS account, and
each is reviewed before the next begins.

| # | Subject | Suite |
|---|---|---|
| 1 | ADR-0009; ADR-0006's and ADR-0007's "four" corrected to six; the ADR index | docs only |
| 2 | Core: the event, the rows, the rejection reason, the ledger's written form. Claim 2, and three of claim 1's tests | `swift test` |
| 3 | Driver: the two-error mapping; the transport reading a forgotten operation as unknown from `finalize` too. Claim 3, and two of claim 1's tests | `swift test` |
| 4 | The negative control, claim 6 | `swift test` |
| 5 | ADR-0010 | docs only |
| 6 | The plane renders a forgotten operation (§3), claim 1's last test | `npm test` |
| 7 | The stack's outputs and its one auth flow, claim 4 | `npm test` |
| 8 | The tree scan and the gitignore entry, claim 4 | `npm test` |
| 9 | The contract suite, its gate, `wrong.ts`, CI's instrument step, claim 5 | `npm test` |
| 10 | `docs/deploy.md` | docs only |
| 11 | **The recorded run**: the Observed sections, README row 4b, `check 4b 6` | docs only |

**No commit here changes a file in `App/`**, so no commit runs the simulator. Core gains an
enum case and the app's own switches over `UploadEvent` carry a `default:` already, so
nothing in the app target stops compiling; if CI's app job reds anyway, that is a red suite
and the task halts.

`docs/invariants.md` gains each claim's tests in the commit that writes them, and
`README.md`'s phase-4b section gains the same claim wording in the same commit, because the
name guard reconciles both directions on every push. `check 4b 6` lands only in commit 11,
when all six exist; before then the phase is unchecked by the claims guard and reconciled by
the name guard, which is the state phase 5 passed through.

## 12. The stale-sentence sweep

Each sentence this phase makes false, and the commit that makes it false. Pointers cite and
never re-record.

| Where | Today | Commit |
|---|---|---|
| `docs/adr/0006` "What this costs" | "§4's four assumptions are unchecked until 4b" | 1: six |
| `docs/adr/0007` §9 | "beside the four falsifiers ADR-0006 §4 already assigned there" | 1: six |
| `docs/adr/0005` O-10 | open | 1: decided by ADR-0009, one line, the reasoning kept |
| `docs/adr/0005` §8 | "a thrown error becomes no event" | 1: one line, scoped by ADR-0009 §2 |
| `docs/adr/0006` §7, and its "Deliberately not decided" bullet | "4b decides the recovery" / "No recovery from an operation the authority no longer has" | 1: one line each, decided by ADR-0009 |
| `docs/adr/0007` costs, "Two ways to be unable to move remain" | stands | 1: one line — both are now a replacement |
| `docs/adr/0007` "Deliberately not decided", the `NoSuchUpload` bullet | "settled in 4b" | 6: settled, and the transport's reading stops being provisional |
| `Sources/DunnageTransport/*` comments citing "4b" for the 404 reading | provisional | 6: the plane's, with the stand-in agreeing |
| `README.md` row 4b | "ADR-0006 §4's four assumptions and ADR-0007's three are checked by a recorded contract run" | 11: six, and the wording below |
| `README.md`, the Status paragraph | "Nothing is deployed, and no byte has reached S3." | 11: deployed once, recorded, destroyed; nothing CI runs reaches S3 |
| `README.md` bird's-eye, control plane | `phase 4a  code only` | 11: deployed once and destroyed |
| `README.md` bird's-eye, data plane | `phase 4b  not built` | 11: observed once; geometry held |
| `docs/architecture/aws.md` | nothing false | not edited |
| the 4a and phase-5 specs | list items this phase lands | not edited; ADR-0009 and ADR-0010 name them, as ADR-0006 §9 did |

**Row 4b's wording at commit 11:**

> The same transport against the deployed plane and S3, run once and recorded: ADR-0006
> §4's six falsifiers and ADR-0007 §9's three assumptions are observations written into
> their ADRs, never CI's. What CI holds is O-10's recovery and a tree that names no account.

## 13. Out of scope

An abort endpoint, and `s3:AbortMultipartUpload` anywhere in the stack — ADR-0006 §6 makes
the abort an operator action and nothing here asks for an endpoint. Idempotency on
`POST /uploads`, still bounded and not prevented. A page loop over
`NextPartNumberMarker`: the handlers refuse a truncated page loudly, and the run does not
reach 1000 parts. A second upload in flight. A checkpoint. Jitter. A per-chunk timeout. A
sign-in flow in the app. An AWS Organization or Control Tower. Any test that sleeps, and any
local load or stress run — CI is the arbiter under load.

## 14. Open at the time of writing

Implementation unknowns, not ADR questions. Each resolves on the first run of the thing it
is about, and is promoted to ADR-0009 or ADR-0010 only if its answer constrains something
later.

- Whether `cdk deploy` of an environment-agnostic stack needs `CDK_DEFAULT_ACCOUNT` and
  `CDK_DEFAULT_REGION` beyond what the credential chain supplies. 4a's third open question
  asked the same of `synth` and the answer was never load-bearing; the procedure is written
  to be correct either way.
- Whether `cdk bootstrap` is needed at all for a stack whose only asset is the handler
  bundle. It is assumed to be, and step 1 exists for that reason; a run that finds it
  unnecessary records so and the step becomes conditional.
- Whether the background session's PUT to S3 carries a header the presigned signature did
  not cover. Nothing suggests it does and the stand-in cannot tell us; question 9 is where
  it would show.
- Whether the app's remembered token surviving its own expiry is a confusing failure on the
  screen. The plane answers 401, `ControlPlaneError.refused(401)` is thrown, no event is
  written and the `note` row shows it. If the run finds that unreadable, it is a line in
  the record and not a change made in advance.
