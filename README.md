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
| **1. Core** | A chunk the transport authority has confirmed is never re-sent, under an identity and payload contract Core does not interpret. An interruption is not a failure: a chunk in flight when the connection drops is unconfirmed, and only the authority settles which. A confirmation folded twice is a confirmation folded once. Giving up is a decision taken against a stated retry budget, and it keeps what the authority confirmed. | landed — 38 named tests, green under `swift test`:<br>testChunkPlanPartitionsThePayloadExactlyOnce<br>testChunkPlanHasNoRangeForAnOrdinalOutsideThePlan<br>testSetShapedAuthorityConfirmsExactlyTheChunksItNames<br>testAuthorityReportingAChunkOutsideThePlanConfirmsNothingExtra<br>testOffsetShapedAuthorityConfirmsOnlyChunksWhollyBelowTheOffset<br>testConfirmationNamingAnotherUploadIsNeverApplied<br>testConfirmationFromAnotherTransportOperationIsNeverApplied<br>testConfirmationNamingThisUploadAndThisOperationIsApplied<br>testAuthorityConfirmedChunk_IsNeverRescheduled<br>testAnUploadWithNoAuthorityReportYetSchedulesEveryChunk<br>testAuthorityReportsNonContiguousParts_ResumeSchedulesOnlyMissingParts<br>testOffsetShapedResumeSendsOnlyTheUnconfirmedSuffixOfAPartialChunk<br>testTransitionTableIsTotal_EveryStateEventPairHasAnExplicitOutcome<br>testTerminalStateIsAbsorbing_EventAfterCompletionIsRejectedWithReason<br>testEffectSequenceForACleanUploadAsksBeforeItSends<br>testTransportReportingATransferCompleteDoesNotConfirmAnything<br>testEventLogStoreAppendsMonotonicallyAndNeverAltersEarlierRecords<br>testEventLogSequencesAreScopedToOneUpload<br>testEventLogEnumeratesEveryUploadItHoldsAndIsEmptyForOnesItDoesNot<br>testEventLogReplayReproducesStateExactly_ForEveryRecordedSequence<br>testTransportDoubleIssuesDistinctSessionsAndRefusesUnknownOnes<br>testTransportDoubleReportsSetShapedProgressIncludingGaps<br>testTransportDoubleReportsOffsetShapedProgressAsAContiguousPrefixOnly<br>testTransportDoubleScriptedToRefuseAnswersNoAndStoresNothing<br>testTransportDoubleScriptedToStallOrToLandSilentlyGivesTheSameNonAnswer<br>testTransportDoubleScriptedToDuplicateDeliversTheSameReportTwice<br>testTransportDoubleThatForgotASessionCannotBeAskedAboutIt<br>testTransportDoubleRefusesToFinalizeAnIncompleteUpload<br>testNetworkInterruptionMidChunk_LeavesTheChunkUnconfirmedNotFailed<br>testDuplicateConfirmation_IsIdempotentUnderReplay<br>testDuplicateConfirmationNeverSchedulesAConfirmedChunk<br>testRetryExhaustion_IsADecisionThatPreservesConfirmedProgress<br>testInterruptionsNeverSpendTheRetryBudgetHoweverManyArrive<br>testBackoffGrowsWithEachAttemptAndIsCarriedByTheSendEffect<br>testARefusalDeliveredTwiceBeforeTheAuthorityAnswersSpendsOneAttempt<br>testARefusalNamingAChunkOutsideThisPlanSpendsNoBudget<br>testWholeObjectTransportDouble_ResendsEveryByteAfterInterruption<br>testUnitHoldingAuthorityAfterTheSameInterruptionResendsOnlyWhatItNeverConfirmed |
| **2. Durable ledger** | The log outlives the process that wrote it: replaying it from disk reproduces state exactly. ADR-0001 O-1 is the open question here. | not started |
| **3. Driver and transport** | The bound holds against a real transport: after an interruption, redundant transfer is bounded by the chunks that were in flight and unconfirmed. | not started |
| **4. Control plane and data plane** | The device never holds an AWS credential, the server derives object ownership from the authenticated principal, and `cdk synth` runs with no cloud credentials. | not started |
| **5. App** | The invariant survives real lifecycle events. A simulated process death is not a SIGKILL, and phase 1 does not claim otherwise. | not started |
