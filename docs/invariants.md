# Invariant by invariant

The named tests behind the invariants `README.md` states. There are two suites now, on two
runners — `swift test` and `vitest` — and this file names every test either of them has. CI
reconciles the union of the two against this list and fails if they disagree in either
direction, and fails as well if a claim is worded differently in the two files.

## Phase 1: Core — a chunk the authority has confirmed is never re-sent

### A chunk names a fixed span, and an authority's answer is read against that span

- `testChunkPlanPartitionsThePayloadExactlyOnce`
- `testChunkPlanHasNoRangeForAnOrdinalOutsideThePlan`
- `testSetShapedAuthorityConfirmsExactlyTheChunksItNames`
- `testOffsetShapedAuthorityConfirmsOnlyChunksWhollyBelowTheOffset`
- `testAuthorityReportingAChunkOutsideThePlanConfirmsNothingExtra`

### A confirmation is evidence about the upload and the operation it names, and nothing else

S3 part numbers are scoped to a multipart `uploadId`, so part 3 of one operation and part 3
of another are unrelated facts.

- `testConfirmationNamingAnotherUploadIsNeverApplied`
- `testConfirmationFromAnotherTransportOperationIsNeverApplied`
- `testConfirmationNamingThisUploadAndThisOperationIsApplied`

### A chunk the authority has confirmed is never handed to a transport again

A set-shaped authority reports a set and not a frontier: holding 1, 2 and 4 says nothing
whatsoever about 3.

- `testAuthorityConfirmedChunk_IsNeverRescheduled`
- `testAnUploadWithNoAuthorityReportYetSchedulesEveryChunk`
- `testAuthorityReportsNonContiguousParts_ResumeSchedulesOnlyMissingParts`
- `testOffsetShapedResumeSendsOnlyTheUnconfirmedSuffixOfAPartialChunk`

### Every event resolves explicitly: a state and its effects, or a reason it changed nothing

- `testTransitionTableIsTotal_EveryStateEventPairHasAnExplicitOutcome`
- `testTerminalStateIsAbsorbing_EventAfterCompletionIsRejectedWithReason`
- `testEffectSequenceForACleanUploadAsksBeforeItSends`
- `testTransportReportingATransferCompleteDoesNotConfirmAnything`

### State comes only from replaying the log, and a cold start finds everything it needs there

- `testEventLogStoreAppendsMonotonicallyAndNeverAltersEarlierRecords`
- `testEventLogSequencesAreScopedToOneUpload`
- `testEventLogEnumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot`
- `testEventLogReplayReproducesStateExactly_ForEveryRecordedSequence`

### An interruption is not a failure, and a duplicate is not progress

See [ADR-0002](adr/0002-interruption-is-not-a-failure.md).

- `testNetworkInterruptionMidChunk_LeavesTheChunkUnconfirmedNotFailed`
- `testDuplicateConfirmation_IsIdempotentUnderReplay`
- `testDuplicateConfirmationNeverSchedulesAConfirmedChunk`

### Giving up is a decision, taken against a budget that says what an attempt is

See [ADR-0003](adr/0003-what-an-attempt-is-and-where-time-enters.md).

- `testRetryExhaustion_IsADecisionThatPreservesConfirmedProgress`
- `testInterruptionsNeverSpendTheRetryBudgetHoweverManyArrive`
- `testARefusalDeliveredTwiceBeforeTheAuthorityAnswersSpendsOneAttempt`
- `testARefusalNamingAChunkOutsideThisPlanSpendsNoBudget`
- `testBackoffGrowsWithEachAttemptAndIsCarriedByTheSendEffect`
- `testBackoffClampsWhenDoublingStepsOverTheCap`

### The doubles keep the contracts they stand in for

A fake that quietly disagrees with the protocol makes every test standing on it worthless,
so the fakes are tested too. The last name below arrived with phase 5 rather than phase 1,
because the double's contract grew when the transport's signatures did (ADR-0007 §3), and
a double whose contract is not tested is one the suite trusts on faith.

- `testTransportDoubleIssuesDistinctSessionsAndRefusesUnknownOnes`
- `testTransportDoubleReportsSetShapedProgressIncludingGaps`
- `testTransportDoubleReportsOffsetShapedProgressAsAContiguousPrefixOnly`
- `testTransportDoubleScriptedToRefuseAnswersNoAndStoresNothing`
- `testTransportDoubleScriptedToStallOrToLandSilentlyGivesTheSameNonAnswer`
- `testTransportDoubleScriptedToDuplicateDeliversTheSameReportTwice`
- `testTransportDoubleThatForgotASessionCannotBeAskedAboutIt`
- `testTransportDoubleRefusesToFinalizeAnIncompleteUpload`
- `testTransportDoubleRefusesAProgressQuestionNamingAnotherUpload`

### The failure mode the thesis claims to remove, kept working on purpose

Interrupt a whole-object transport at 80% and every byte goes again; interrupt a
unit-holding authority at the same point and only the four bytes it never confirmed do.
The difference is the transport's contract, not the client's diligence — and if the first
of these ever stops losing its work, the control has been broken.

- `testWholeObjectTransportDouble_ResendsEveryByteAfterInterruption`
- `testUnitHoldingAuthorityAfterTheSameInterruptionResendsOnlyWhatItNeverConfirmed`

## Phase 2: Durable ledger — the log outlives the process that wrote it

The durable ledger: a second implementation of `UploadEventLog`, backed by a file. See
[ADR-0004](adr/0004-the-on-disk-ledger-and-what-an-unreadable-record-does.md).

### Every event has one written form on disk, and reading it back gives the event that was written

The format is a decision, not a shape derived from how Core spells itself. The encoder
switches over `UploadEvent` with no `default:`, so a new case in Core is a compile error
until its written form is chosen.

- `testEveryEventKindHasOneWrittenFormAndSurvivesTheRoundTrip`
- `testTheWrittenFormOfAnEventIsPinnedByTheFormatAndNotBySwiftsSynthesis`

### A record naming an event this binary does not know is never guessed at

ADR-0001 O-1, decided by ADR-0004. Skipping it derives a state that is wrong and looks
fine; refusing derives nothing. Worse for availability, better for the invariant.

- `testARecordNamingAnEventThisBinaryDoesNotKnowIsNeverGuessedAt`
- `testACompleteRecordThisBinaryCannotInterpretIsRefusedRatherThanRepaired`
- `testALedgerWrittenInAFormatThisBinaryDoesNotKnowIsRefusedRatherThanRead`
- `testAFileInTheLedgerDirectoryThisModuleDidNotWriteIsRefusedRatherThanIgnored`

### The state derived by replaying from disk is the state the writer held

Every cold start here is a second `FileEventLog` over the same directory, which is all a new
process would have. The same contract the in-memory double keeps, kept by the file too: a
contract only one implementation is measured against describes that one.

- `testStateReplayedFromDiskIsTheStateTheWriterHeld`
- `testTheFileLedgerAppendsMonotonicallyAndNeverAltersEarlierRecords`
- `testTheFileLedgerScopesSequencesToOneUpload`
- `testTheFileLedgerEnumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot`
- `testAnAbsentLedgerIsAColdStartWithNothingYetAndNotAnError`
- `testUploadsThatACaseInsensitiveFilesystemCouldConfuseGetSeparateLedgers`
- `testAnUploadIdentifierTooLongToNameAFileIsRefusedRatherThanShortened`

### A torn tail is not an event, and replay stops before it rather than at it

Every file behind these is constructed byte by byte. None of them is evidence about a
process death: that is a lifecycle claim and it belongs to the device harness. See the
honesty boundary in ADR-0004.

- `testATornTailIsNotAnEventAndReplayStopsBeforeIt`
- `testAppendingAfterATornTailReplacesTheTornBytesRatherThanWritingPastThem`
- `testTornUnknownAndAbsentAreThreeAnswersAndNeverOne`
- `testBytesThatWereAllThereAreNotATearAndAreRefusedRatherThanTrimmed`

### Two uploads are never one ledger, however late in their identifiers they differ

The other link in the chain the naming rules stand on. The claim above asserts the
mechanisms — hex rather than base64url, and a refusal rather than a shortened name. This
asserts what those mechanisms are for, without depending on either of them being the way it
is reached: a scheme that shortened a name to fit would break this, and a collision-free
scheme that was not a refusal would break neither.

The two halves are different situations. Names that fit give two ledgers and `uploads()`
reports two. Names that do not fit are refused, so there are none — which is why the
assertion there is that there is never *one*, and not that there are always two.

- `testTwoUploadsThatDifferOnlyLateInTheirIdentifiersAreNeverOneLedger`

### The failure mode a completeness marker removes, kept working on purpose

Two bytes short of finishing one write. A ledger with no completeness marker reads
`chunks 11 12 13` as `chunks 11 12 1`, because a truncated ordinal is a perfectly good
ordinal and nothing in the file says the record never finished — so chunk 1 is dropped from
the plan and never sent, and no authority ever said it holds it. The framed ledger, given
the same cut write, derives that the authority never answered. The difference is the marker,
not the diligence of the reader, and the marker-less ledger keeps the same protocol
contract to prove it.

Phase 1's control is a different failure: bytes re-sent that were confirmed. This one is the
thesis failing from the other end, bytes skipped that were not. If the marker-less ledger
ever stops losing this, the control has been broken.

- `testTheMarkerlessLedgerKeepsTheContractItIsMeasuredAgainst`
- `testALedgerWithNoCompletenessMarkerDerivesProgressNobodyConfirmed`
- `testTheFramedLedgerAfterTheSameTornWriteDerivesOnlyWhatWasDurablyRecorded`

## Phase 3: Driver — it executes Core's effects and concludes nothing of its own

The driver, and the clock it waits behind. See
[ADR-0005](adr/0005-the-driver-and-the-clock-it-waits-behind.md).

Nothing in this phase touches a network or a real clock. What it establishes is that the
driver keeps the contract ADR-0002 and ADR-0003 wrote for it before any of it existed; it
establishes nothing about the world, and the ADR's honesty boundary says so at length.

### A transport's answer becomes one event, on the log, before the next transfer begins

The mapping adds nothing: a report, a refusal and an absent answer are three events, and no
driver is allowed to make one of them out of another.

The ordering is not tidiness. `Attempts` is derived from the log, so a refusal still in
memory when the process goes away is an attempt that never happened — and an upload that
dies on every attempt would then retry for ever, which is the failure a retry budget exists
to stop.

- `testEachOfTheThreeAnswersBecomesTheOneEventThatMeansIt`
- `testAnAnswerIsOnTheLogBeforeTheNextTransferBegins`

### The wait a send has earned is honoured before the transfer, by the driver's own clock

`after` is a duration Core computed from the policy and the attempts already spent. The
driver is the thing that waits, and this is the only place backoff exists.

- `testTheWaitOnASendIsHonouredBeforeTheTransferAndByTheInjectedClock`
- `testTheOnlyWaitsTheDriverTakesAreTheOnesTheEffectsCarried`

### A transfer that never answers is an interruption, and how long the driver waited is the driver's alone

A timeout is driver policy, and this is where the whole of it lives. Stopping produces the
event that already means "no answer arrived", so a transport that said so and a driver that
stopped waiting for one leave the log identical — there is no duration on it, no third event,
and nothing that lets the fold tell them apart.

Every test here gives each chunk one attempt. A driver that called a quiet transfer a
refusal would spend the only attempt there is, and the upload would fail instead of
finishing, so each of these is an assertion about the budget as well.

- `testATransferQuietLongerThanTheDriversTimeoutBecomesAnInterruption`
- `testAQuietTransferAndAnAnsweredInterruptionLeaveTheSameLog`
- `testATransferThatAnswersInsideTheTimeoutIsNotQuiet`

### An upload picked up from the log asks the authority before it sends anything

Replay discards effects on purpose, so a state arriving from the log has no work attached to
it and the driver needs a rule for what to do with one. The rule is the weakest effect each
phase already produces on entry, and `send` is not among them: a driver that carried on from
the log's last answer would send against an answer given before the process died, and the
authority may well have moved past it.

- `testAnUploadPickedUpFromTheLogAsksTheAuthorityBeforeItSendsAnything`
- `testAnUploadPickedUpBeforeAnyTransportOperationOpensOneAndThenAsks`
- `testAnUploadWithNothingOutstandingIsLeftAloneWhenItIsPickedUp`

### Giving up reaches the log because Core asked for it, and for no other reason

`.abandoned` is the only event that reaches a terminal phase, so what puts it on the log is
what makes `.failed` a decision rather than a drift.

The first of these is checkable from the log alone, which is the property worth having:
whatever the driver was thinking at the time, an abandonment nobody asked for is visible for
ever afterwards to anyone who replays the prefix in front of it. The second gives a driver
every excuse and no reason — a chunk stalled, waited out past the timeout, and stalled
again, with nothing ever refusing anything.

- `testEveryAbandonmentOnTheLogIsOneCoreAskedFor`
- `testADriverGivenEveryExcuseToGiveUpAppendsNoAbandonmentCoreDidNotAskFor`

### Phase 3's doubles keep the contracts they stand in for

The clock is what makes every timing assertion in this phase deterministic, and the journal
is what makes an ordering between two objects readable at all. A fake that quietly disagrees
with the thing it replaces makes every test standing on it worthless.

- `testTheVirtualClockLetsAWaitElapseOnlyWhenATestHasGrantedIt`
- `testTheVirtualClockSpendsAGrantOnOneWaitAndNoMore`
- `testTheVirtualClockAbandonsAWaitItsTaskNoLongerNeeds`
- `testTheDoubleScriptedOnceAnswersThatWayOnceAndThenAsItWasBefore`
- `testTheDoubleScriptedToNeverAnswerDoesNotAnswerUntilItsTaskIsCancelled`
- `testTheJournallingLogKeepsTheContractOfTheOneItWraps`
- `testTheJournallingTransportAnswersExactlyWhatTheOneItWrapsAnswers`

### The failure mode a driver that concludes reintroduces, kept working on purpose

Phase 1's control is bytes re-sent that were confirmed. Phase 2's is bytes skipped that were
not. This one is neither: it is an upload abandoned that nothing was wrong with.

`ConcludingDriver` is the same loop with one line different — an interruption recorded as a
refusal, the collapse ADR-0002 exists to remove, arriving on the other side of the boundary
from where that ADR removed it. Nothing else about it is wrong: it keeps no tally and reaches
no conclusion, and every abandonment it writes is one Core asked for. The fault is upstream of
all of that, in what it says happened, and Core is then correct about evidence that is false.

Same transport, same script, same policy, same clock with the same backoffs granted. A chunk
goes quiet three times and then lands, and nothing anywhere ever answers no. One driver
finishes the upload. The other gives up on it with four of the five chunks confirmed, one
transfer short of the one that would have finished it — and the log it leaves is internally
consistent, which is what makes this the dangerous one.

It is never "fixed". If the concluding driver stops giving up here, the control has been
broken and the real driver has nothing left to be measured against.

- `testTheConcludingDriverKeepsTheContractItIsMeasuredAgainst`
- `testADriverThatCallsAnInterruptionARefusalGivesUpOnAnUploadNothingRefused`
- `testTheRealDriverAfterTheSameInterruptionsFinishesTheUpload`

## Phase 4a: Control plane — it decides where a caller's bytes may land from the token it verified

The control plane, and the half of phase 4 a reader can check with no AWS account. Nothing
here is deployed: every test reaches a pure function, an assertion about a synthesised
template, or the path a handler takes before it constructs a client — and no test in this
phase is evidence about any AWS account. See
[ADR-0006](adr/0006-the-control-plane-and-the-identity-it-composes.md).

These are the first tests in this file that `swift test` does not run. They are `vitest`, in
`cloud/test/`, on a second runner.

### The stack synthesises with no account, no region and no credential, and nothing it does can quietly acquire one

The stack declares no `env`, so its account and region are unresolved tokens and the template
names no environment. Nothing in the template is a twelve-digit account written out, no source
under `bin/`, `lib/` or `handlers/` calls `fromLookup` or reaches a `ContextProvider`, and
every `AWS::Lambda::Function` reads its code from a prebuilt S3 asset rather than from
anything assembled while `cdk` was running. `NodejsFunction` is refused for that reason: it
bundles at synth time with local esbuild when present and Docker when not, which would make
the property depend on what happens to be installed on the machine. The JWT issuer is the
user pool's own `ProviderURL` attribute, resolved by CloudFormation at deploy, and not a
region this repository wrote down.

The source scan reads code and not prose. `lib/stack.ts` explains in its comments why it
refuses `NodejsFunction` and what a `fromLookup` would cost, and a scan over raw text reads
that explanation as the violation it warns against; comments are stripped before anything is
matched, so the assertion is about what a source does. Weakening the pattern until it stopped
matching, or deleting the explanation, would each have turned a passing test into a worse
document.

The last of the five is not about credentials at all. It reconciles the environment variable
name the stack sets against the one the four handlers read, because nothing in this phase
deploys and a stack setting `BUCKET_NAME` beside handlers reading `BUCKET` would synthesise
green and fail at the first real request in 4b. What it asserts is the whole set of names the
handlers read rather than the presence of the one it is looking for, so a handler that began
reading a second variable would be reported instead of passed over.

What this does not establish: nothing here is deployed, and a synthesised template is a
document rather than evidence about any AWS account. CI synthesises again with the AWS
environment scrubbed rather than merely absent, so a runner that later gains OIDC does not
start passing for a different reason — and, honestly, that scrubbing is not load-bearing
today: with no credential anywhere on this machine the scrubbed template is byte-identical to
the bare one. `--no-lookups` is the guard against a `fromLookup` arriving later, not a thing
doing work now.

- `testTheStackSynthesisesWithNoAccountNoRegionAndNoCredential`
- `testTheStackDeclaresNoEnvironmentAndLooksNothingUp`
- `testTheLambdaCodeIsAPrebuiltAssetAndNothingBundlesDuringSynth`
- `testTheJWTIssuerRendersAsATokenAndNotALiteralRegion`
- `testEveryHandlerFunctionIsHandedTheBucketUnderTheNameItsHandlerReads`

### A device holds no principal and no standing grant on the bucket: each authority it does hold names one operation on one part, and expires

The device holds a JWT and never an AWS credential. There is a user pool and an app client and
no identity pool, which is the stronger form of the claim rather than a narrower one: an
identity pool is the only thing in Cognito that exchanges a token for AWS credentials, so
without one there is no role a device could assume at all. Every role the template declares is
assumable by an AWS service and by nothing else — a `Federated` principal is how a web
identity becomes an assumable role and an `AWS` principal is how an account or a user does,
and neither appears in a trust policy here — and every `Allow` on the bucket names a role this
stack defines, so nothing outside the stack holds a standing grant on it.

What a device is handed instead is one signed request per part. The control plane signs it
with its own role's authority, so the PUT a device makes carries a permission the device
itself never holds. Each URL names one key, one uploadId, one part number and one operation,
and carries an `X-Amz-Expires`, so it stops working on its own. Two parts of one upload are
two URLs that differ in the part number and in the signature that covers it and in nothing
else. The claim states what each authority is scoped to and says nothing about how many of
them there are, because a five-part upload hands out five.

The URLs are signed offline. The presigner builds a canonical request and an HMAC chain out of
the credentials it is handed and reaches no network, so both tests run on a machine holding no
AWS credential and touching no bucket, with obviously-fake placeholders standing in for a key
pair. `handlers/urls.ts` names no credential and no region of its own — `signPartUrl` takes an
already-built client — which is what keeps the set of environment variables the handlers read
equal to `BUCKET` alone and leaves the fake pair in the test file and nowhere else.

The bucket-policy assertion reads principals and not actions, and that boundary is deliberate.
CDK's auto-delete-objects provider reaches the bucket through an `Allow` carrying `s3:List*`,
which matches `s3:ListMultipartUploadParts`; that is a question about actions, and the claim
about the enumeration permission below is what answers it — the provider does hold that
permission through that `Allow`, and claim 5's holder set names it as a role this stack
defines and no device can become.

What this does not establish: nothing here is deployed. The three template assertions cannot
go red without sabotaging the stack — there is no identity pool to remove and no foreign
principal to add — and none was manufactured so that one could be watched failing. The two URL
tests establish that the authority is *shaped* as narrowly as the claim says, and not that S3
enforces that shape: the fourth falsifier in
[ADR-0006](adr/0006-the-control-plane-and-the-identity-it-composes.md) §4 — that a presigned
PUT signed for one part number and one uploadId is refused for any other — needs a real
bucket, and 4b's recorded contract run owns it.

- `testTheStackDeclaresNoIdentityPool`
- `testEveryRoleInTheTemplateIsAssumableOnlyByAnAWSService`
- `testEveryAllowInTheBucketPolicyNamesARoleThisStackDefines`
- `testAPresignedURLIsScopedToOneMethodOneKeyOnePartAndAShortExpiry`
- `testTwoPartsOfOneUploadAreTwoDifferentSignedRequests`

### The object key is derived from the authenticated principal, and a field the client sends never reaches it

The key is `uploads/<sub>/<ref>`, and the `sub` in it comes from the verified token and from
nowhere else. A body naming a `key`, a `sub` or a `userId` produces the key a body without
them produces — not because a handler strips those fields, but because `objectKey(sub, ref)`
has no third parameter one of them could arrive through, and `verifiedSub` is the only
function in the service that reads a principal. A check can be omitted at one of four call
sites; a parameter that does not exist cannot be passed at any of them.

A token carrying no `sub` claim is refused with a 401. There is no default principal and no
empty prefix to fall back to: an empty prefix is a place one caller's reference reaches
another caller's object, so two callers deliberately kept apart would land on one.

What happens after the S3 call carries no test here, and nothing is faked to make it look
tested. A stubbed `S3Client` would be a double of a vendor's product rather than of a
contract this repository states, so writing one would encode a guess about AWS and then run
the guess against itself. 4b's recorded contract run against a real bucket is what checks
that half, and [ADR-0006](adr/0006-the-control-plane-and-the-identity-it-composes.md) §4
names the four observations that would falsify these handlers.

- `testTheObjectKeyIsDerivedFromTheVerifiedPrincipalAndTheRefAlone`
- `testARequestBodyNamingAKeyOrASubProducesTheSameKeyAsOneWithout`
- `testAMissingSubClaimIsRefusedRatherThanDefaulted`

### A reference the caller supplies names a leaf inside its own prefix or it is refused, never repaired

Refused, and not repaired into something acceptable. Sanitising maps two distinct references
onto one key, and two uploads that the caller kept apart then become one object.

The separator is the exclusion that carries weight beyond this phase. A `TransportSessionID`
is `<ref> "/" <uploadId>`, and phase 5's `parseSession` splits it on the first `/`; that
parse is total only because no reference this server accepts contains one. Different
language, different suite, different phase, and nothing a compiler or a test runner sees
connects the two — so the rule lives in
[ADR-0006](adr/0006-the-control-plane-and-the-identity-it-composes.md) §2, and
`testARefContainingASeparatorIsRefused` is the only thing that enforces it.

The grammar is also what a handler applies before it acts. Each of the four handlers answers
400 to a reference of `../etc` without constructing a client, which is why a test about a
server runs on a machine holding no credential at all.
`testAHandlerRefusesARefTheGrammarRejectsBeforeItActs` is filed under this claim rather than
under claim 3 because what it refuses is this grammar; that it refuses before it acts is the
other half of the same decision. What it asserts is the reason the refusal gives and not
only its status code. Three of the four — `urls`, `parts` and `complete` — carry a second
guard that also answers 400, and no one request satisfies all of them at once: `parts` reads
its `uploadId` from the query string, so a body carrying one never reaches it, and with its
grammar check deleted it still answered 400 for a different reason. `create` is the fourth
and has no second guard; with its grammar check deleted it reaches a client construction
instead, and the suite records that throw as its answer rather than letting it take the
other three with it.

- `testARefThatIsNotALeafInTheCallersOwnPrefixIsRefusedRatherThanRepaired`
- `testARefContainingASeparatorIsRefused`
- `testARefAtTheGrammarsBoundariesIsAccepted`
- `testAHandlerRefusesARefTheGrammarRejectsBeforeItActs`

### The control plane holds nothing its routes do not use, and every principal that can enumerate parts is one this stack defines and no device can become

Each of the four routes holds the permission its own S3 calls need, and no other. `create`
calls `CreateMultipartUpload` and holds `s3:PutObject`; `parts` calls `ListParts` and holds
`s3:ListMultipartUploadParts`; `complete` makes both calls and holds both; `urls` makes no S3
call at all and holds `s3:PutObject`, because a presigned URL carries the authority of the
principal that signed it and the device's PUT is made with the signing role's permission and
never with one of its own. The claim says *use* rather than *call* for that reason. What the
split buys is a property and not a saving: a function that only signs URLs, and one that only
opens an operation, cannot enumerate anybody's parts. The abort case is the same clause at
zero — no route aborts, so nothing in the template may, and what says so is a holder set that
comes back empty rather than a string that fails to appear.

The permission is looked for wherever a grant can live. A role holds an action through the
statements attached to it — inline, or in an `AWS::IAM::Policy` that names it — and a
principal holds one through the bucket policy's `Allow`, and the assertion reads both, with
IAM's own wildcards expanded rather than matched as text. It has to: CDK's auto-delete-objects
provider holds no S3 action in its role at all and reaches the bucket through an `Allow`
carrying `s3:List*`, which matches `s3:ListMultipartUploadParts`, so a test that read roles
would report four holders and pass while the claim was false of the template. The set asserted
is exact rather than "no other holds it", because a negative passes when the scan reads
nothing: no role in this template carries an inline `Policies` at all, so a reader that
stopped there would return an empty set and report success having read none.

"No device can become" is not re-proved here. Every principal in the holder set is a role this
stack declares, and that every such role is assumable by an AWS service and by nothing else is
what claim 2's `testEveryRoleInTheTemplateIsAssumableOnlyByAnAWSService` establishes. This
claim rests on that one rather than repeating it.

What this does not establish: nothing here is deployed, and a synthesised template is a
document rather than evidence about any AWS account. `AWSLambdaBasicExecutionRole`'s contents
are AWS's and are not in the template, so what a role holds through it is pinned by name
instead of expanded — a role attaching any other managed policy reds the map rather than
widening invisibly. And that `s3:PutObject` is the permission `CreateMultipartUpload`,
`UploadPart` and `CompleteMultipartUpload` all require is
[ADR-0006](adr/0006-the-control-plane-and-the-identity-it-composes.md) §6's statement of
documented AWS behaviour, not something this phase executed.

- `testEachFunctionRoleHoldsOnlyThePermissionsItsOwnRouteUses`
- `testEveryPrincipalThatCanEnumeratePartsIsOneThisStackDefines`
- `testNothingInThisTemplateMayAbortAMultipartUpload`

### The failure mode a client-trusted key reintroduces, kept working on purpose

Phase 1's control is bytes re-sent that were confirmed. Phase 2's is bytes skipped that
were not. Phase 3's is an upload abandoned that nothing was wrong with. This one is none
of those: every byte goes exactly once, to exactly the object the request named, and two
callers who were never told apart anywhere else end up sharing it.

`cloud/test/client-trusted-key.ts` is `handlers/create.ts` with one line different — the
key read out of the request body instead of composed by `objectKey(sub, ref)`. Nothing
else about it is wrong. It verifies the token, refuses a request whose token carries no
`sub`, and refuses a reference the grammar rejects, all before it acts and all with
create's own status codes and reasons. The fault is upstream of every check it makes, in
what it believes about the request, and the 200 it answers is then correct about a key
that was never its to choose.

Two callers, `sub-1` and `sub-2`, one reference, and the same `key` in both bodies. The
control answers both and hands back one object. The same two requests through
`verifiedSub` and then `objectKey` produce two keys, because `objectKey` has no third
parameter the body's `key` could arrive through — the difference is the composition and
not the diligence of the handler around it.

The first of the three tests is what makes the other two mean what they claim. The
control's answers to a missing `sub` and to `../etc` are compared against create's rather
than restated, so the collision below is evidence about a client-trusted *key* and not
about some handler that refuses nothing — a handler answering 200 to everything would
collide too, and would establish nothing. Both handlers are asked through one `respond`,
in `support.ts`, because a comparison between two handlers has to be made with one
instrument.

The control stops where every test of a real handler in this phase stops. create's 200
branch calls S3 and no test here reaches an S3 call, so the control returns the key it
would have used where create returns an uploadId — a failure that happened inside a call
this machine cannot make would demonstrate nothing. That is a second difference from
create, and it is named rather than folded into the first.

It lives under `cloud/test/` and never under `cloud/handlers/`, and four things make it
inert rather than merely filed out of the way. `vitest.config.mts` includes only
`test/**/*.test.ts`, so it is imported by a suite and never collected as one.
`SOURCE_DIRS` in `synth.test.ts` is `['bin', 'lib', 'handlers']`, so claim 1's scan over
the stack's own sources never reads it. The build script names `handlers/*.ts` one by one,
so nothing bundles it into a Lambda asset and no route could reach it. And `tsconfig.json`
includes `test`, so it is typechecked under the same strict settings as everything else:
inert is not unchecked.

It is never "fixed". If the client-trusted handler stops putting two callers on one
object, the control has been broken and `create` has nothing left to be measured against.

- `testTheClientTrustedKeyHandlerKeepsTheContractItIsMeasuredAgainst`
- `testAClientTrustedKeyPutsTwoCallersOnOneObject`
- `testTheDerivedKeyAfterTheSameTwoRequestsKeepsTheCallersApart`

## Phase 5: App — the transfer outlives the process that started it

The app, and the transport it owns. See
[ADR-0007](adr/0007-the-transfer-that-outlives-the-process-and-the-stand-in-it-is-measured-against.md).

Three tiers, and each section below says which its tests are in. Deterministic is
`swift test` or the app's unit-test bundle: a virtual clock, no session, no socket.
Simulator evidence is `xcodebuild test` on the CI image against the stand-in, where one
named test kills the process and reads the relaunch from outside. The device harness is a
numbered procedure on a real iPhone, recorded and never CI's evidence. Nothing under this
heading touches a session.

### A background task names one chunk of one upload, and a task this transport did not name is never read as progress

All five are deterministic, under `swift test`. The description is the one string the
system persists with a task across relaunch, so it is all a relaunched process has to say
whose task it is. It is a JSON object with sorted keys and not a joined string, because
both the upload id and the composed session identity may contain `/`, and a delimiter that
either side may contain is a parse that is not total (ADR-0007 §4). The composed identity
is `<ref>/<uploadId>`, split on the first separator so an upload id may contain one, and
exactly three inputs are refused with `.unrecognisedSession` — no separator, an empty ref,
an empty uploadId; the list is three and not two only while ADR-0006 §4's third falsifier
holds, that S3 never returns an empty upload id. The parse's call site carries the comment
ADR-0006 §2 requires, naming `testARefContainingASeparatorIsRefused` as the only thing
that keeps it total. A task whose description does not decode — a missing key, a chunk
below one, a session that does not parse, a key this transport never writes, or a string
that is not the one this transport writes for those values — is cancelled at adoption and
never registered, so nothing it might seem to show reaches any upload.

- `testATaskDescriptionRoundTripsAndItsKeysAreSorted`
- `testADescriptionThisTransportDidNotMintDecodesToNothing`
- `testASessionIdentitySplitsOnTheFirstSeparatorSoAnUploadIdMayContainOne`
- `testExactlyThreeInputsAreNotASessionThisTransportMinted`
- `testATaskWhoseDescriptionThisTransportDidNotMintIsCancelledAndNeverReadAsProgress`

### A chunk has at most one transfer in flight, and a send for a chunk already in flight waits on it rather than starting another

All eight are deterministic, under `swift test`. A `send` adopts the task already running
for its `(session, chunk)` or creates exactly one, and awaits it; two sends that race create
one, because the description is marked as creating before the first await and the second
send finds the mark. Adoption keeps one task per description, the lowest id after sorting by
id — the rule must not depend on the order the session lists them, which `URLSession` does
not promise — and cancels the rest. The injected fault is the cancelled await, which is what
the driver's timeout does: it resumes the await throwing `CancellationError`, removes its
waiter, and touches nothing in the journal, and a second send for the chunk creates nothing
(ADR-0007 §4; the coincidence ADR-0005 §5 named ends here). A creation that fails resumes
every send waiting on that chunk with the same error, because a waiter must always have a
task or an error and one on a creation that failed waits on nothing; the driver treats it
as any thrown error (ADR-0005 §8). URLs are minted at `send`, every
send, so the task's life and the URL's begin together and the transport holds no cache and
no clock (ADR-0007 §6, F2). The control plane is reached through `PlaneExchange`, a request
in and a response out, and the routes' bytes are `ControlPlaneWire`'s pure functions; claim
6 does not grow here, because the canned plane is a closure the test hands in, with its
answers and its request journal local to the test, and a wrapper that holds no state keeps
no contract a test could check. `openSession` calls `POST /uploads` and `send` calls `POST
/uploads/{ref}/urls`; the first test above holds all four routes beside the handlers that
speak them, because the pure half is one function per route and reads no state. On the
wire, 400, 401 and 403 are `refused`, and any other status outside 2xx is
`unexpectedStatus`: a 5xx is the plane failing, not refusing, and the two are kept apart
for the reason Core keeps a refusal and an interruption apart. The `.noSuchUpload` reading
of 404 is provisional — the stand-in's, until 4b shows what the plane renders (ADR-0007 §9,
item 2).

- `testEachRouteIsBuiltAndReadExactlyAsThePlaneSpeaksIt`
- `testOpenSessionAsksThePlaneOnceAndComposesTheIdentityFromItsAnswer`
- `testASendMintsItsURLAtSendAndCreatesOneTaskNamedForTheChunk`
- `testAChunkHasAtMostOneTransferInFlightWhenTwoSendsRace`
- `testASendForAChunkAlreadyInFlightWaitsOnItRatherThanStartingAnother`
- `testAdoptionKeepsTheFirstTaskPerChunkAndCancelsADuplicate`
- `testAnAwaitCancelledMidTransferLeavesTheTaskRunningAndASecondSendCreatesNothing`
- `testWaitersOnAChunkWhoseCreationFailedAreResumedWithTheFailure`

### What a session reported is an answer the driver received, and confirmed progress comes only from what the authority holds

All nine are deterministic, under `swift test`. The completion listener maps each
completion the session reports to exactly one outcome and to no other: a 2xx is a report, a
status that is not 2xx is a refusal — the transport answered, and the answer was no — and no
answer at all is an interruption (ADR-0007 §5). The ETag is not read, because the session
never sees one. A completion no send was awaiting is held in memory, handed to the first
send that asks for that chunk and then forgotten; it never reaches the log, because the log
records answers a driver received and a driver that never asked was never answered. A
completion whose id is registered under no description — a task cancelled at adoption still
reports — is dropped, because it is not evidence about any upload. The listener starts with
`adopt()` and not in `init`, as one `Task` that runs for the process's lifetime and is
never cancelled; that it is started once is a code guard and not an invariant with a test,
because two iterators on one `AsyncStream` split its elements rather than duplicating them
and a second listener is not observable from outside. Either way a completion takes its
task out of the registry, which is the expired-URL path (ADR-0007 §6): a PUT presented with
a URL that has expired is refused, and the next send for that chunk creates anew with a URL
minted at that send. **A task is registered before it is started**, so a completion can
never arrive for a task this transport has not yet named: `PartTaskSession` separates
creating a task from starting it, as `URLSession` does, and `send` creates, registers, then
starts. Started first, a completion could name an id the registry did not hold yet and be
dropped as not this transport's, leaving a send waiting on an answer that had been and gone
and every later send adopting a dead entry — ordering removes that rather than a rule about
what to do afterwards (ADR-0007 §4). Confirmed progress comes from `GET
/uploads/{ref}/parts` and from nothing else, whatever any completion said (ADR-0001 §3);
the answer is set-shaped because the authority's is, a part number below one or one that is
not an integer is refused rather than filtered away, and reading past the one page
`parts.ts` serves is 4b's. `finalize` names one refusal: a complete over parts the authority
does not hold, which the plane today cannot make — it does not know the plan's N and
completes over whatever `ListParts` returns — so the stand-in's 400 is what the case is
written against, and Core finalizes only once every chunk is confirmed, which leaves the
authority having lost a part between the ask and the complete. The last two tests are the
ones that could not be written before: the driver one is the sentence ADR-0005 §5 could not
make, a transfer that outlives the wait the driver gave it and is answered by the next send
without a second task, and the listener one is the only test here that goes through the
session rather than calling the listener's `deliver` directly, so the wiring `adopt()`
starts is covered rather than assumed. With all four calls on the actor,
`BackgroundSessionTransport` declares its `UploadTransport` conformance.

- `testEachCompletionBecomesTheOneOutcomeThatMeansIt`
- `testACompletionNoSendWasAwaitingIsHandedToTheFirstSendThatAsksAndThenForgotten`
- `testACompletionForATaskThisTransportDidNotNameIsDropped`
- `testAPutPresentedWithAnExpiredURLIsRefusedAndTheNextSendMintsAFreshOne`
- `testConfirmedProgressComesOnlyFromWhatTheAuthorityHolds`
- `testFinalizeAsksThePlaneToCompleteAndAnIncompleteRefusalIsNamed`
- `testATransferThatOutlivesTheDriversWaitIsAnsweredByTheNextSendWithoutASecondTask`
- `testTheListenerAdoptionStartsDeliversWhatTheSessionReports`
- `testACompletionCannotArriveForATaskThisTransportHasNotYetNamed`

### A cold start finds the payload on the log, and a chunk file is a cache bounded by the in-flight set

All six are deterministic, under `swift test`. ADR-0006 O-12 found the gap: a relaunched
process had the destination and the plan on the log and no way to find the bytes. The
intent now carries `PayloadRef`, the declaration on disk carries it inside `"intent"`, and
the ledger's format is 2 (ADR-0007 §8). The second test went red genuinely — a version-1
header was accepted while the format was still version 1 — and it keeps 1 refused rather
than read, because no version-1 log exists outside this suite and a reader that defaulted
the payload for one would be a migration written for a file no one has. A chunk file is
written at `send` from the ref and the plan's range, holds exactly that span, is deleted
when the authority confirms the chunk, and is re-derived by the next `send` if it is ever
missing (ADR-0007 §7). A payload shorter than the plan is refused rather than written
short, because a short chunk file would be sent as if it were whole; the fifth test is the
guard's, and was shown red by removing the guard. The sixth puts the cache's lifecycle
against the transport that performs it: three sends write three files, a completion reports
one of them and all three are still there, and it is the authority's own answer to `/parts`
that deletes the two it confirms. The double's own contract for the parameter
`confirmedProgress` gained is under phase 1's heading, where the rest of that contract is.

- `testAColdStartFindsThePayloadOnTheLog`
- `testAVersionOneHeaderIsRefusedAndItsVersionIsNamed`
- `testAChunkFileHoldsExactlyTheSpanThePlanNames`
- `testTheChunkFilesThatExistAtOnceAreBoundedByTheInFlightSet`
- `testAPayloadShorterThanThePlanIsRefusedRatherThanWrittenShort`
- `testAChunkFileIsDiscardedWhenTheAuthorityConfirmsTheChunkNotWhenACompletionReports`

### Phase 5's doubles keep the contracts they stand in for

All three are deterministic, under `swift test`. The scripted wire stands in for
`PartTaskSession`, this repository's contract for the daemon and the wire together, and
never for `URLSession`: a double of a vendor's product runs a guess against itself
(ADR-0007 §9). It holds exactly the tasks seeded or created and forgets a cancelled one,
delivers each completion once in the order the test gave them, and counts a receipt per
task created whose description names a part and none for one that does not parse. This
claim grows once, in commit 7, when the stand-in's own tests and its parity diff against
the plane arrive with the stand-in.

- `testTheScriptedWireHoldsExactlyTheTasksCreatedOrSeededAndForgetsACancelledOne`
- `testTheScriptedWireDeliversEachCompletionOnceInTheOrderTheTestGaveThem`
- `testTheScriptedWireCountsAReceiptPerTaskCreatedAndNoneForAnUnparseableOne`
