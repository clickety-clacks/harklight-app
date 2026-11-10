# Independent launch and inbox comparison

Date: 2026-11-10. Work item: wi_0abf79e7-b0d8-4961-9754-86f99d83b28e.
Assignment: asg_93747f14-5492-488b-a1b8-65a54f0f4a8a.
Isolated branch: compare/core-fable52-rerun-perf2. Nothing pushed or merged.

Base: 803fe1547dfd1f3cacc314d4e510b99050116f53.
Performance change: fd4aa5a891dc5093a2b143fdbc3002f3ce71648a.
Separate test-fixture correction: 9e007c72733d18a8e63c2ac4f1828faca4f9fac6.
Older-server Seen expectation: 991f9f95876dd010a4476ac4be28698047525f39.
Final application/test source: acce9d0d48a430bd59ce26a2c85a68f582f21f31.

## Change and evidence

Bulk inbox rendering checked retraction by request key even though it already
held the corresponding request. That called a linear search of all requests for
every row. A two-second sample during the base 10,000-message launch captured
1,284 of 1,285 main-thread samples in this repeated lookup.

The fix passes the existing request to retraction checks in inbox rows, expired
retraction search rows, and the next-expiry calculation. A timestamp overload
preserves the same precedence: explicit thread retraction, reported retraction,
then a receipt refusing the answer because of retraction. There is no new cache
or change to durable state, selection, drafts, transport, or response semantics.

## Process-cold launch measurements

Xcode 27.2 (27B52), iOS 27.0 (24A434), iPhone 17 Pro simulator, Debug build.
Each measured run starts a terminated app process on an already booted simulator.
OS caches remain warm. These are **simulator timings, not device timings**.

The synthetic workload contains exactly 1,000 or 10,000 distinct small legacy
action messages. Generate it using Scripts/generate-launch-fixture.py, supplying
the original bundled fixture, count, and output path. Substitute the output for
the test app's attention-client-m2-fixtures.json resource. Sizes are 301,049 and
3,010,049 bytes. Restore the original fixture for ordinary tests.

InboxColdLaunchTests first seeds durable local state with
--reset-attention-fixture. It then performs three launches with
--attention-fixture. It measures monotonic elapsed time from app.launch() to an
existing, hittable request-row-review-01. It taps that row, verifies
message-card-scroll, records another elapsed time, and retains a screenshot.
This includes XCTest launch, idleness and accessibility-query overhead, bundled
fixture parsing, and fixture registration. It excludes live enrollment, relay
connection, network paging, and server latency.

| Workload | Revision | Tappable inbox seconds, runs 1 / 2 / 3 | Detail visible seconds, runs 1 / 2 / 3 |
| --- | --- | --- | --- |
| 1,000 | Base | 14.245 / 14.196 / 14.040 | 16.053 / 16.276 / 16.088 |
| 1,000 | Fixed | 6.049 / 6.250 / 6.333 | 7.814 / 7.953 / 8.461 |
| 10,000 | Base | No completed measured runs | No completed measured runs |
| 10,000 | Fixed | 15.301 / 15.425 / 14.969 | 17.798 / 17.697 / 17.271 |

The base 10,000-message seed launch failed: no event-loop idle notification at
66.18 seconds; the subsequent UI snapshot query timed out; the test failed at
108.722 seconds. This is a timeout observation, not a completed launch time or
a precise lower bound on first visual paint. No speedup ratio is claimed for it.
There was one such seed attempt. All six fixed measured launches reached and
opened the selected message.

The initial baseline used build-for-testing/test-without-building with local
signing disabled. After clarification, fixed runs used the repository's
unmodified Scripts/verify.sh test with its local ad-hoc signature. Both use the
same Debug application code and UI measurement harness apart from the repair;
the different invocation/signature is an experimental limitation.

An earlier invalid generated fixture was rejected by the parser and displayed
the explicit load-error screen. That trial is excluded. Corrected workloads
were accepted by the exact base domain parser before timing.

## Remaining delay

The fixed 10,000-message median remains 15.301 seconds in this test. A separate
10-second seed-launch sample captured 6,234 main-thread samples, including 2,616
in application initialization, 2,234 in PrototypeStore initialization, and 1,128
in LivePresentationStore initialization. Request projection and row construction
still run; the nested lookup bottleneck is removed. These are nested sample
counts, not independent phase durations. Seed persistence encoding differs from
the measured retained-state launches. The measurements do not justify a broader
restructure or quantify live-account launch phases.

## Crash investigation limit

The originally reported crash was not reproduced or established. Investigation
examined base launch/restoration, presentation, repeated row lookups, forced
failure sites, and uniqueness checks. The observed base failure was the
10,000-message UI responsiveness timeout. A bounded log read on the owned
simulator found no matching app crash/fatal messages during that exercise.
This does not exclude a crash with other data or on a physical device.
No crash-cause, watchdog-termination, or crash-regression claim is made.

## Tests and observed runtime

Final scoped verification at application source acce9d0 on the standard iOS 27.0
phone passed all 87 tests, zero failures and zero skips, through the unmodified
wrapper. This includes all three authorized repairs, the neighboring other-device
refusal case, large-inbox preservation, and the retraction/freshness/answer/badge
suites below.

Historical focused run before the three repairs: 87 tests, three failing tests
(four assertions).
All tests passed in AnswerStatusPresentationTests (16),
InboxBadgeCountTests (7), InboxFreshnessReplayTests (17),
RetractionPresentationTests (13), and the new large-inbox preservation test (1).
The latter verifies 1,000 rows, selected request, exact saved draft, and unchanged
durable revision. Thirty of 33 LiveAnswerConfirmationTests passed.

The same three failures and four assertions were reproduced on the untouched
base. One was an incorrect Got it fixture in a test expecting informational Seen
presentation; the separate fixture commit supplies the explicit Seen descriptor.
Its focused verification passed (one test, zero failures) through the unmodified
wrapper at test-fixture commit 9e007c7; see seen-fixture-repair.log.

The product owner resolved both behavior questions. Older-server Seen answers
remain truthfully shown as Seen; only the test expectation changed, retaining
its checks that no phone-specific receipt is created. The duplicate-send handler
now clears the error if the refreshed request is answered and retains this
account's submitted answer, even when the device receipt is hidden. A first
attempt after another device answered still receives the existing refusal.
All three repaired cases and the neighboring other-device refusal test passed
in the full suite at application source acce9d0. The original duplicate-send
regression assertions, including no second intent, remain intact.

Ordinary synthetic fixture taps cannot reach the late production callback:
fixture delivery is disabled, and answered controls disable normal submission.
The app-hosted test exercises the actual handler on the simulator using an
in-memory relay and checks the error and intent count. A visibly reproduced late
callback in the UI is not claimed; no live account or service was used.

The full-suite run and failure attribution are recorded below. Delivery
ownership assigned broader failures to this lane for attribution only; repairs
are limited to lane-introduced regressions. Full-suite green is not claimed.

Two additional UI tests passed through the unmodified wrapper:
- ReplyDraftPersistenceUITests/testUnsentChoiceSurvivesLeavingAndReopeningRequest
- RetractionExpiryRelaunchUITests/testPersistedRetractionExpiresAfterAppProcessRelaunch

The retraction test includes its existing 195-second deadline wait; both tests
finished with zero failures. The six benchmark screenshots show rendered detail
for 1-of-1,000 and 1-of-10,000 messages, body, answer choices and navigation/chat
controls. XCTest actually tapped the inbox row before each capture. Supplementary
read-only screenshot inspection found no visible clipping, overlap or error
overlay; it is not an independent acceptance verdict.

## Full-suite failure attribution

The full iOS 27.1 Duo wrapper run at acce9d0 completed with 615 tests:
565 passed, 46 failed, 4 skipped. Delivery ownership explicitly scoped this lane
to attribution of broader failures and repair only of lane-introduced failures.
Full-suite green is **not claimed**.

All 45 assertion failures reproduced on exact base and head on Duo with matching
assertion substance. On the standard iOS 27.0 phone, 32 fail on both versions,
with matching assertions; 13 pass on both and are recorded as Duo-only
observations. No lane-introduced assertion failure was found. The table below
identifies areas and assertion details for separate ownership. A regular-width
precondition and a requested 250-point column that was not achieved are explicit
applicability/fixture limits, not evidence that those layouts should work on a
compact phone.

The 46th failure interrupted an annotation test: the test process threw
NSInternalInconsistencyException because a conversation replay test callback
fulfilled an XCTestExpectation multiple times. The annotation case and named
replay test passed alone on head/base Duo and head phone; annotation also passed
alone on base phone. Both passed in a subsequent quiet head/base Duo selection.
This is intermittent test-process evidence, with the exact trigger unestablished;
it does not establish the original reported application launch crash.

Quiet four-case confirmation started with no other xcodebuild observed. No
competing build was observed at 5-second samples during either run. Both explicit
UI wait failures persisted on head and base; annotation and replay tests passed.
Quiet head/base selections took 84.484/77.675 seconds. Main comparisons ran on the shared
host with concurrent builds recorded; those are not claimed quiet. Standard
phone is the applicable comparison target per delivery ownership; Duo-only
observations are not repaired in this lane.

## Reproduction and evidence locations

Use an owned iOS 27 simulator and an isolated checkout. Run one build at a time per isolated checkout; the attribution runs used a shared host.

    HARKLIGHT_SIMULATOR_ID=<owned-device> \
      HARKLIGHT_ONLY_TESTING=HarklightUITests/InboxColdLaunchTests \
      Scripts/verify.sh test

Unit selections and preservation UI selections are the named suites/tests above.
The wrapper regenerates the project and uses its checkout's DerivedData.
The checked-in generated project initially omitted FreeRenderedHost; regeneration
resolved the baseline build failure without a product-code change.

The assignment's private evidence report supplies absolute paths and exact
commands. Evidence filenames include:
base-1000-valid.log/.xcresult, base-10000.log/.xcresult,
base-10000-render.sample.txt, after-unit.log,
base-existing-failures.log, after-1000.log, after-10000.log,
after-10000-seed.sample.txt, after-preservation-ui.log,
after-1000-attachments/, and after-10000-attachments/.

## Per-case routing table

| Area | Test | Phone head | Phone base | Attribution / assertion substance |
| --- | --- | --- | --- | --- |
| Conversation presentation | `HarklightTests/ConversationPresentationTests/testAgentReplyStaysUnreadUntilChatShowsItAcrossForegroundAndRelaunch` | failed | failed | Reply unread state remains true where false is expected after chat/foreground/relaunch. Assertion lines 711,714. |
| Conversation presentation | `HarklightTests/ConversationPresentationTests/testInboxChatMarkerNeedsAChatTurnAndKeepsClosedUnreadRepliesVisible` | failed | failed | Chat marker true where false is expected. Assertion lines 772. |
| Conversation presentation | `HarklightTests/ConversationPresentationTests/testShakeExamplesIncludeRevisionArchiveDistinctFileFactsAndClosureWithoutOperations` | failed | failed | Expected ConversationFile is absent. Assertion lines 665. |
| Enrollment | `HarklightTests/NativeGuidedJoinTests/testLostRemovalReplyKeepsOriginalKeyAndResumesBeforeFreshReplacement` | failed | failed | Replacement/confirmation phases, request count, old receipt removal and replacement identity assertions fail (805,809–811,814,817); generated values omitted. Assertion lines 805,809,810,811,814,817. |
| Enrollment | `HarklightTests/NativeGuidedJoinTests/testRestartAfterReplacementRequestSavedBeforeOldReceiptCleanupKeepsTheNewRequest` | failed | failed | Expected departure receipt is nil at 864; generated enrollment values omitted. Assertion lines 864. |
| Navigation / UI | `HarklightConversationUITests/ConversationSampleUITests/testChatHistoryKeepsKeyboardUntilDownwardSwipe` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightConversationUITests/ConversationSampleUITests/testCompactBackLeavesMessageButClosingChatDoesNotAbandonItsUpload` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightConversationUITests/ConversationSampleUITests/testConversationRevisionFileFactsAndClosureUseTheOrdinaryApp` | failed | failed | Chat composer remains enabled after explicit conversation closure. Assertion lines 1244. |
| Navigation / UI | `HarklightConversationUITests/ConversationSampleUITests/testNavigationKeepsUnsubmittedUploadCleanupTruthfulAcrossAdaptiveRebuild` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightConversationUITests/ConversationSampleUITests/testOrdinaryConversationSharesAdaptivePanelWithoutLiveServices` | failed | failed | Local example · nothing sent status text absent. Assertion lines 801. |
| Navigation / UI | `HarklightConversationUITests/ConversationSampleUITests/testPriorityRowsAndNewMessageAreaRenderIn250PointListColumn` | failed | failed | Phone measured width 750/rendered 874 versus requested 250; sample approval row absent. Narrow-column fixture not achieved. Assertion lines 48,50,56,64,79. |
| Navigation / UI | `HarklightConversationUITests/ConversationSampleUITests/testRetractedItemKeepsItsSelectedChoiceHistoryAndUnsentDiscussion` | failed | failed | Selected choice/discussion elements absent; sample-chat-composer snapshot unavailable. Assertion lines 1188,1189,1195,1196. |
| Navigation / UI | `HarklightConversationUITests/FreeRenderedUITests/testCapturedFreeNewSelectionAndReadTransition` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightConversationUITests/FreeRenderedUITests/testGeneratedLegacySectionsAreTruthfulAndHistoryRemainsReachable` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/AdaptiveDuoNavigationUITests/testLandscapeSelectionKeepsListAndDetailVisibleAcrossMessages` | failed | failed | Regular-width precondition unmet on phone; side-by-side list/row absent and review row cannot be tapped. Layout applicability limitation, not proof of phone navigation regression. Assertion lines 84,99,101,105. |
| Navigation / UI | `HarklightUITests/HarklightUITests/testAcceptedAnswerShowsKnownAnsweredSceneThroughSharedFixture` | failed | failed | Inbox tab element absent after answering at 294. Assertion lines 294. |
| Navigation / UI | `HarklightUITests/HarklightUITests/testNativeBackKeepsInboxListPositionForUntouchedRequest` | failed | failed | Header brand remains hittable beyond a 5-second hidden predicate wait. Assertion lines 447. |
| Navigation / UI | `HarklightUITests/HarklightUITests/testNativeInteractiveBackReturnsToSearchableList` | failed | failed | Seen confirmation element absent at 571. Assertion lines 571. |
| Navigation / UI | `HarklightUITests/HarklightUITests/testSharedPointDraftAndExactReceiptRemainAvailable` | failed | failed | Expected floor-plan prompt text absent at 41. Assertion lines 41. |
| Navigation / UI | `HarklightUITests/HarklightUITests/testSplitViewAdaptationKeepsTheSelectedMessage` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/InboxStockTabsUITests/testInboxAndRepliedPullToRefreshRunAndKeepFailureVisible` | failed | failed | First request row absent before pull-to-refresh at 143. Assertion lines 143. |
| Navigation / UI | `HarklightUITests/InboxStockTabsUITests/testNativeHeaderMinimizesOnDownScrollAndRestoresOnUpScroll` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/InboxStockTabsUITests/testNativeListSearchKeepsInboxAndRepliedResults` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/RetractionExpiryRelaunchUITests/testServerRetractionExpiresInForegroundAndAfterProcessRelaunch` | failed | failed | Server-retraction persistence readback element absent; scenario cannot reach expiry assertion. Assertion lines 45,46. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testBoundaryPullAndAdaptiveChat` | failed | failed | Expected next Search card not visible after boundary navigation. Assertion lines 1234,1235. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testCorrectedInboxDuoOrientations` | failed | failed | Expected chat sheet/composer absent. Assertion lines 1028,1030,1031. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testDesignedControlsAndComponentScreenshots` | failed | failed | Controls missing at 841/959; prefilled unsent reply unexpectedly treated as replied at 849. Assertion lines 841,959,849. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testNativeInboxHeaderUsesCompactNavigationBarOnIPhone` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testNoCommentIsAvailableForReplyOnlyRequests` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testOrdinaryInboxKeepsRequestsAlongsideTestFixtures` | failed | failed | Cover A element absent. Assertion lines 209. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testPreviewPageCapturesInboxAndDetail` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testRecoveryWarningStaysAvailableWithoutCoveringToolbarActions` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testSubmittedRequestHistoryRemainsWhileLocalExamplesAreUsed` | failed | failed | Cover A element absent. Assertion lines 256. |
| Navigation / UI | `HarklightUITests/SampleWorkspaceUITests/testUnsupportedNoCommentControlStaysVisibleAndCanBeRetried` | failed | failed | request-no-comment-unavailable element absent. Assertion lines 563,564. |
| Relay / conversation | `HarklightNativeRelayTests/NativeRelayCoreTests/testCheckpointReconcilesAcceptedOriginalAndAppliesItsActualTerminalSequenceOnce` | failed | failed | Answer JSON member-order equality differs: op_id last versus after type; values otherwise match apart from per-run UUID. Assertion lines 1419. |
| Relay / conversation | `HarklightNativeRelayTests/NativeRelayCoreTests/testRejectedPostCheckpointACKDoesNotAttachAgainOnSameSession` | failed | failed | Observed inbox_start,inbox_checkpoint_ack,inbox_attach versus expected inbox_start,inbox_attach. Assertion lines 1279. |
| Relay / conversation | `HarklightTests/ConversationRelayTests/testLegacyDeliveryNeedsNoConversationProjection` | failed | failed | Throws invalidReplay. Assertion lines 1041. |
| Relay / conversation | `HarklightTests/ConversationRelayTests/testUnknownRelayUpdateIsNotedSkippedAndAcknowledged` | failed | failed | Throws invalidReplay. Assertion lines 1091. |
| Release notes | `HarklightTests/ReleaseNotesTests/testBuildSeventyEightReplyCheckmarkNoteIsFixedAndHiddenUntilThatBuild` | failed | failed | Release-note containing build 119 versus expected 79. Assertion lines 164. |
| Release notes | `HarklightTests/ReleaseNotesTests/testBuildSeventyNineEdgePullRemovalNoteIsFixedAndHiddenUntilThatBuild` | failed | failed | Release-note containing build 119 versus expected 79. Assertion lines 147. |
| Release notes | `HarklightTests/ReleaseNotesTests/testBuildSeventySevenInboxAnswerRecoveryNoteIsFixedAndHiddenUntilThatBuild` | failed | failed | Release-note containing build 119 versus expected 79. Assertion lines 180. |
| Release notes | `HarklightUITests/ReleaseNotesUITests/testPost79UpdateShowsEarliestConfirmedContainingBuildWithoutRelabeling` | passed | passed | Duo failure; passed on standard phone head. No repair proposed for this device-specific observation. |
| Response presentation | `HarklightTests/HarklightTests/testOwnOperationReceiptDoesNotJumpCursorAndEnablesKnownAnswerScene` | failed | failed | Accepted own outcome absent; zero rather than one scene; projected scene nil. Assertion lines 1697,1702,1703. |
| Revision presentation | `HarklightTests/SenderRevisionPresentationTests/testAcceptedSenderUpdateRetainsEarlierChoicesTurnsAndQueuedAnswerBinding` | failed | failed | Inbox status lacks expected Updated prefix. Assertion lines 39. |
| TLS / response presentation | `HarklightTests/NativeGuidedTLSTests/testStaleNoCommentAtRevisionThreeReturnsOpenRequestToInbox` | failed | failed | Answer not delivered label absent. Assertion lines 1511. |

| Test-process / intermittent | `HarklightTests/SampleLibraryTests/testAnnotationUndoReversesTheLatestActionAcrossTools` | passed alone | passed alone | Full-suite process interrupted by repeated XCTestExpectation fulfillment in earlier replay-test callback; passes alone and in quiet head/base Duo confirmation. Class(c), intermittent; exact trigger not established. |
