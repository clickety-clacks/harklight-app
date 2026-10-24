# Harklight Client

Standalone native SwiftUI fixture app showing three sender documents: an illustrated response, a facilities point-and-note task, and an unfamiliar interface that remains inert. The sender documents determine their supported scenes and exact result shapes. The earlier `actions/1` fixture remains a compatibility regression input.

This demonstration uses fictional bundled data. The native app retains its local draft and receipt state across restarts; it has no authenticated relay, source action, or production delivery. The dedicated Demo controls screen explains that fixture outcomes are simulated and never delivered to a relay or source; normal request tasks and read-only details contain no simulation controls.

Harklight is the current product name. The Xcode project, app target, and shared scheme are named `Harklight`. The app uses `co.clicketyclacks.Harklight` for its bundle ID. Historical `Attention` domain symbols and fixture keys remain unchanged for compatibility.

The corrected sender-document examples are bundled in `Resources/attention-client-m2-fixtures.json`; the same fixtures are used by the native host boundary tests. The previous M2 fixture remains in `attention-client-m2-r1-compat.json` for subset regressions. Renderer grammar and exact-result behavior are exercised by the source and tests.

The Xcode project is generated from `project.yml` with XcodeGen. Run `Scripts/verify.sh build`, `Scripts/verify.sh test`, or `Scripts/verify.sh run` with Xcode and a selected booted simulator. The default destination is the existing iPhone Duo; set `HARKLIGHT_SIMULATOR_ID` to use an iPad or another simulator for product validation. `run` installs and launches on that destination and saves a CoreSimulator screenshot. For `test`, set `HARKLIGHT_ONLY_TESTING` to space-separated test identifiers (for example `HarklightUITests/SampleWorkspaceUITests/testDesignedControlsAndComponentScreenshots`) to run only those tests; without it the full suite runs. Desktop-window screenshots use Xcode Device Hub. Follow the repository [Harklight guidance](HARKLIGHT_GUIDANCE.md) for tests and gates.

## UI preview screenshot pages

Run `Scripts/capture-preview-page.py` on a Mac with Xcode 27.1 or later and a booted iPhone Duo simulator. Set `HARKLIGHT_SIMULATOR_ID` to that simulator's UUID; the command refuses to choose a default device. It builds through the unchanged `Scripts/verify.sh build` action, installs the app, launches its local sample inbox, then captures each changed screen from the simulator display. For each screen, use Device Hub to set the requested open, partly folded, or closed outer-display pose and each interface orientation supported by the built iPhone app. The command captures both system appearances at each pose and orientation, then writes one static page with a single switch that changes all screenshots together.

Pass the timestamp recorded when the change was pushed so the page can report change-to-page time. Keep generated pages outside the source repository. The page and its PNG files form one folder and can be served privately for review; use only a temporary server bound to a private network address, and stop it after review.

```sh
HARKLIGHT_SIMULATOR_ID=<booted-iPhone-Duo-UUID> \
  Scripts/capture-preview-page.py \
  --page-dir "$HOME/Library/HarklightPreviews/palette-iteration" \
  --page-title "Palette iteration" \
  --pushed-at "2026-10-23T15:12:00Z" \
  --screen inbox=Inbox \
  --screen message-detail="Message detail"
```
