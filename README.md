# Harklight Client

Standalone native SwiftUI fixture app showing three sender documents: an illustrated response, a facilities point-and-note task, and an unfamiliar interface that remains inert. The sender documents determine their supported scenes and exact result shapes. The earlier `actions/1` fixture remains a compatibility regression input.

This demonstration uses fictional bundled data. The native app retains its local draft and receipt state across restarts; it has no authenticated relay, source action, or production delivery. The dedicated Demo controls screen explains that fixture outcomes are simulated and never delivered to a relay or source; normal request tasks and read-only details contain no simulation controls.

Harklight is the current product name. The Xcode project, app target, and shared scheme are named `Harklight`. The app uses `co.clicketyclacks.Harklight` for its bundle ID. Historical `Attention` domain symbols and fixture keys remain unchanged for compatibility.

The corrected sender-document examples are bundled in `Resources/attention-client-m2-fixtures.json`; the same fixtures are used by the native host boundary tests. The previous M2 fixture remains in `attention-client-m2-r1-compat.json` for subset regressions. Renderer grammar and exact-result behavior are exercised by the source and tests.

The Xcode project is generated from `project.yml` with XcodeGen. Run `Scripts/verify.sh build`, `Scripts/verify.sh test`, or `Scripts/verify.sh run` with Xcode and a selected booted simulator. The default destination is the existing iPhone Duo; set `HARKLIGHT_SIMULATOR_ID` to use an iPad or another simulator for product validation. `run` installs and launches on that destination and saves a CoreSimulator screenshot. For `test`, set `HARKLIGHT_ONLY_TESTING` to space-separated test identifiers (for example `HarklightUITests/SampleWorkspaceUITests/testDesignedControlsAndComponentScreenshots`) to run only those tests; without it the full suite runs. Desktop-window screenshots use Xcode Device Hub. Follow the repository [Harklight guidance](HARKLIGHT_GUIDANCE.md) for tests and gates.

For focused tests in the `NativeRelay` Swift package, set `HARKLIGHT_NATIVE_RELAY_ONLY_TESTING` to a space-separated list of XCTest method names. `Scripts/verify.sh test` runs those package tests through `xcrun swift test`; if `HARKLIGHT_ONLY_TESTING` is also set, it then runs those Xcode tests in the same wrapper invocation. With only the NativeRelay variable set, the wrapper exits after the package tests without selecting a simulator. To run the focused inbox recovery tests together with their release-note test through the canonical wrapper:

```sh
HARKLIGHT_NATIVE_RELAY_ONLY_TESTING="testInboxReconciliationAddsPersistedNoCommentIDWithoutChangingOrdinaryFrame testMissingInboxResultStaysPendingWhileOtherResultsCheckpointAndDeliveryContinue testRefusedInboxOperationDisablesOnlyThatIntentAndContinuesOtherDelivery testReconciledNoCommentMayProjectBeyondSnapshotWithoutAdvancingCheckpoint testReconciliationAdoptsExistingNoCommentTerminalForUnseenOperationID" \
HARKLIGHT_ONLY_TESTING="HarklightTests/ReleaseNotesTests/testBuildSeventySevenInboxAnswerRecoveryNoteIsFixedAndHiddenUntilThatBuild" \
Scripts/verify.sh test
```

## UI preview screenshot pages

`Scripts/capture-preview-page.py` runs a targeted simulator UI capture through the unchanged `Scripts/verify.sh test` wrapper, once in light appearance and once in dark appearance. The capture scenario opens the sample Inbox, searches for `Archive`, selects the matching request, and captures the Inbox and selected detail. It uses the portrait orientation and does not change or infer the simulator's fold state. The page includes one switch for both appearances and records the source revision, capture timestamps, screenshot hashes and change-to-page time.

Set `HARKLIGHT_SIMULATOR_ID` to a booted iPhone Duo simulator. The generated page folder must be outside the source checkout.

```sh
HARKLIGHT_SIMULATOR_ID=<booted-iPhone-Duo-UUID> \
  Scripts/capture-preview-page.py \
  --page-dir "$HOME/Library/HarklightPreviews/palette-iteration" \
  --page-title "Palette iteration" \
  --pushed-at "2026-10-26T15:12:00Z"
```

This capture path currently produces portrait screenshots only. It does not capture landscape or fold states.
