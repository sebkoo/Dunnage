# Dunnage

[![CI](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml/badge.svg)](https://github.com/sebkoo/Dunnage/actions/workflows/ci.yml)
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)
![Platforms: iOS 17, macOS 14](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-lightgrey.svg)
![License: Apache 2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

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

See `docs/adr/0001-transport-boundary-and-confirmed-progress.md` and
`docs/adr/0002-interruption-is-not-a-failure.md`, and
`docs/adr/0003-what-an-attempt-is-and-where-time-enters.md`.

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
     Durable ledger                              phase 2   not built
       the append-only event log, on disk
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
| **2. Durable ledger** | The log outlives the process that wrote it: replaying it from disk reproduces state exactly. ADR-0001 O-1 is the open question here. | not started |
| **3. Driver and transport** | The bound holds against a real transport: after an interruption, redundant transfer is bounded by the chunks that were in flight and unconfirmed. | not started |
| **4. Control plane and data plane** | The device never holds an AWS credential, the server derives object ownership from the authenticated principal, and `cdk synth` runs with no cloud credentials. | not started |
| **5. App** | The invariant survives real lifecycle events. A simulated process death is not a SIGKILL, and phase 1 does not claim otherwise. | not started |

## Phase 1, invariant by invariant

Every name below states its invariant rather than its method, which makes the list the
shortest honest description of what this library refuses to do. They are written out for
that reason, grouped by what they establish rather than by the file they live in.

`swift test` runs all of them, with no AWS access key, no SSO session and no cloud
configuration of any kind. CI fails if this list and the suite disagree in either
direction.

### A chunk names a fixed span, and an authority's answer is read against that span

A confirmation is meaningless if the bytes a chunk refers to can move underneath it, and
an answer that named something outside the plan would widen a claim the authority never
made.

- `testChunkPlanPartitionsThePayloadExactlyOnce`
- `testChunkPlanHasNoRangeForAnOrdinalOutsideThePlan`
- `testSetShapedAuthorityConfirmsExactlyTheChunksItNames`
- `testOffsetShapedAuthorityConfirmsOnlyChunksWhollyBelowTheOffset`
- `testAuthorityReportingAChunkOutsideThePlanConfirmsNothingExtra`

### A confirmation is evidence about the upload and the operation it names, and nothing else

S3 part numbers are scoped to a multipart `uploadId`, so part 3 of one operation and part 3
of another are unrelated facts. Applying one upload's answer to another would mark chunks
confirmed that nobody ever confirmed — and the thesis would then decline to send them,
forever.

- `testConfirmationNamingAnotherUploadIsNeverApplied`
- `testConfirmationFromAnotherTransportOperationIsNeverApplied`
- `testConfirmationNamingThisUploadAndThisOperationIsApplied`

### A chunk the authority has confirmed is never handed to a transport again

The thesis itself, under both confirmation shapes, because it is not allowed to depend on
which contract is in play. A set-shaped authority reports a set and not a frontier: holding
1, 2 and 4 says nothing whatsoever about 3.

- `testAuthorityConfirmedChunk_IsNeverRescheduled`
- `testAnUploadWithNoAuthorityReportYetSchedulesEveryChunk`
- `testAuthorityReportsNonContiguousParts_ResumeSchedulesOnlyMissingParts`
- `testOffsetShapedResumeSendsOnlyTheUnconfirmedSuffixOfAPartialChunk`

### State is a total fold over an append-only log, and over nothing else

Every (state, event) pair resolves explicitly, terminal states absorb, and a cold start that
replays from nothing lands where the running process stood. A transport saying "that
transfer finished" moves none of it: Core records the observation and goes and asks.

- `testTransitionTableIsTotal_EveryStateEventPairHasAnExplicitOutcome`
- `testTerminalStateIsAbsorbing_EventAfterCompletionIsRejectedWithReason`
- `testEffectSequenceForACleanUploadAsksBeforeItSends`
- `testTransportReportingATransferCompleteDoesNotConfirmAnything`
- `testEventLogStoreAppendsMonotonicallyAndNeverAltersEarlierRecords`
- `testEventLogSequencesAreScopedToOneUpload`
- `testEventLogEnumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot`
- `testEventLogReplayReproducesStateExactly_ForEveryRecordedSequence`

### An interruption is not a failure, and a duplicate is not progress

A chunk in flight when the connection drops is unconfirmed — it may have landed and it may
not, and only the authority can say. A confirmation that arrives twice is on the log twice,
because the log is append-only, and folding it twice has to derive what folding it once
derives. See `docs/adr/0002-interruption-is-not-a-failure.md`.

- `testNetworkInterruptionMidChunk_LeavesTheChunkUnconfirmedNotFailed`
- `testDuplicateConfirmation_IsIdempotentUnderReplay`
- `testDuplicateConfirmationNeverSchedulesAConfirmedChunk`

### Giving up is a decision, taken against a budget that says what an attempt is

`.failed` is terminal and absorbing, so nothing may drift into it. An attempt is a refusal;
an interruption is not one, or a flaky network would exhaust the budget of chunks that were
never in trouble. An upload that gave up keeps what the authority had confirmed. See
`docs/adr/0003-what-an-attempt-is-and-where-time-enters.md`.

- `testRetryExhaustion_IsADecisionThatPreservesConfirmedProgress`
- `testInterruptionsNeverSpendTheRetryBudgetHoweverManyArrive`
- `testARefusalDeliveredTwiceBeforeTheAuthorityAnswersSpendsOneAttempt`
- `testARefusalNamingAChunkOutsideThisPlanSpendsNoBudget`
- `testBackoffGrowsWithEachAttemptAndIsCarriedByTheSendEffect`
- `testBackoffClampsWhenDoublingStepsOverTheCap`

### The doubles keep the contracts they stand in for

A fake that quietly disagrees with the protocol makes every test standing on it worthless,
so the fakes are tested too. This one models both authority shapes, because choosing one
would bake that choice into everything above.

- `testTransportDoubleIssuesDistinctSessionsAndRefusesUnknownOnes`
- `testTransportDoubleReportsSetShapedProgressIncludingGaps`
- `testTransportDoubleReportsOffsetShapedProgressAsAContiguousPrefixOnly`
- `testTransportDoubleScriptedToRefuseAnswersNoAndStoresNothing`
- `testTransportDoubleScriptedToStallOrToLandSilentlyGivesTheSameNonAnswer`
- `testTransportDoubleScriptedToDuplicateDeliversTheSameReportTwice`
- `testTransportDoubleThatForgotASessionCannotBeAskedAboutIt`
- `testTransportDoubleRefusesToFinalizeAnIncompleteUpload`

### The negative control, which is never fixed

The failure mode the thesis claims to remove, kept working. Interrupt a whole-object
transport at 80% and every byte goes again; interrupt a unit-holding authority at the same
point and only the four bytes it never confirmed do. The difference is the transport's
contract, not the client's diligence — and if the first of these ever stops losing its
work, the control has been broken.

- `testWholeObjectTransportDouble_ResendsEveryByteAfterInterruption`
- `testUnitHoldingAuthorityAfterTheSameInterruptionResendsOnlyWhatItNeverConfirmed`
