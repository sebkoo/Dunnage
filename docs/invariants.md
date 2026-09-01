# Invariant by invariant

The named tests behind the invariants `README.md` states. CI fails if this list and the
suite disagree in either direction, and if a claim is worded differently in the two files.

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

## Phase 2: Durable ledger — the log outlives the process that wrote it

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
`docs/adr/0005-the-driver-and-the-clock-it-waits-behind.md`.

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
