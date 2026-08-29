# Invariant by invariant

The named tests behind the invariants `README.md` states. CI fails if this list and the
suite disagree in either direction, and if a claim is worded differently in the two files.

## Phase 1, invariant by invariant

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

See `docs/adr/0002-interruption-is-not-a-failure.md`.

- `testNetworkInterruptionMidChunk_LeavesTheChunkUnconfirmedNotFailed`
- `testDuplicateConfirmation_IsIdempotentUnderReplay`
- `testDuplicateConfirmationNeverSchedulesAConfirmedChunk`

### Giving up is a decision, taken against a budget that says what an attempt is

See `docs/adr/0003-what-an-attempt-is-and-where-time-enters.md`.

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

## Phase 2, invariant by invariant

The durable ledger: a second implementation of `UploadEventLog`, backed by a file. See
`docs/adr/0004-the-on-disk-ledger-and-what-an-unreadable-record-does.md`.

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
