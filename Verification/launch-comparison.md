# Independent launch and inbox comparison

Date: 2026-11-10. Work item: wi_0abf79e7-b0d8-4961-9754-86f99d83b28e.
Assignment: asg_93747f14-5492-488b-a1b8-65a54f0f4a8a.
Isolated branch: compare/core-fable52-rerun-perf2. Nothing pushed or merged.

Base: 803fe1547dfd1f3cacc314d4e510b99050116f53.
Performance change: fd4aa5a891dc5093a2b143fdbc3002f3ce71648a.
Separate test-fixture correction: 9e007c72733d18a8e63c2ac4f1828faca4f9fac6.

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

Focused unit run: 87 tests, three failing tests (four assertions).
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

Two behavior questions remain pending product ruling:
- Whether an older-server authorized Seen answer should produce Seen status.
- Whether a delayed send after an accepted, answered request should display the
  no-longer-open error once the completed projection hides device receipts.

Neither those tests nor their production behavior has been changed. The branch
is not claimed fully green or complete while these questions remain.

Two additional UI tests passed through the unmodified wrapper:
- ReplyDraftPersistenceUITests/testUnsentChoiceSurvivesLeavingAndReopeningRequest
- RetractionExpiryRelaunchUITests/testPersistedRetractionExpiresAfterAppProcessRelaunch

The retraction test includes its existing 195-second deadline wait; both tests
finished with zero failures. The six benchmark screenshots show rendered detail
for 1-of-1,000 and 1-of-10,000 messages, body, answer choices and navigation/chat
controls. XCTest actually tapped the inbox row before each capture. Supplementary
read-only screenshot inspection found no visible clipping, overlap or error
overlay; it is not an independent acceptance verdict.

## Reproduction and evidence locations

Use an owned iOS 27 simulator and an isolated checkout. Run one build at a time.

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
