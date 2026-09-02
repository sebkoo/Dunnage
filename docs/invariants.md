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
so the fakes are tested too.

- `testTransportDoubleIssuesDistinctSessionsAndRefusesUnknownOnes`
- `testTransportDoubleReportsSetShapedProgressIncludingGaps`
- `testTransportDoubleReportsOffsetShapedProgressAsAContiguousPrefixOnly`
- `testTransportDoubleScriptedToRefuseAnswersNoAndStoresNothing`
- `testTransportDoubleScriptedToStallOrToLandSilentlyGivesTheSameNonAnswer`
- `testTransportDoubleScriptedToDuplicateDeliversTheSameReportTwice`
- `testTransportDoubleThatForgotASessionCannotBeAskedAboutIt`
- `testTransportDoubleRefusesToFinalizeAnIncompleteUpload`

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
is `<ref> "/" <uploadId>`, and 4b's `parseSession` splits it on the first `/`; that parse is
total only because no reference this server accepts contains one. Different language,
different suite, different phase, and nothing a compiler or a test runner sees connects the
two — so the rule lives in
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
