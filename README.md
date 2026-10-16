# Harklight Client

Standalone native SwiftUI fixture app showing three sender documents: an illustrated response, a facilities point-and-note task, and an unfamiliar interface that remains inert. The sender documents determine their supported scenes and exact result shapes. The earlier `actions/1` fixture remains a compatibility regression input.

This demonstration uses fictional bundled data. The native app retains its local draft and receipt state across restarts; it has no authenticated relay, source action, or production delivery. The dedicated Demo controls screen explains that fixture outcomes are simulated and never delivered to a relay or source; normal request tasks and read-only details contain no simulation controls.

Harklight is the current product name. Historical `Attention` code symbols, fixture keys, file names, bundle ID of the simulator prototype remain unchanged for continuity. The simulator bundle is not the intended signed product identity; `co.clicketyclacks.Harklight` is the intended same-app physical bundle/topic, subject to Apple registration, signing, and device verification.

The corrected sender-document examples are bundled in `Resources/attention-client-m2-fixtures.json`; the same fixtures are used by the native host boundary tests. The previous M2 fixture remains in `attention-client-m2-r1-compat.json` for subset regressions. Renderer grammar and exact-result behavior are exercised by the source and tests.

The Xcode project is generated from `project.yml` with XcodeGen. Run `Scripts/verify.sh build`, `Scripts/verify.sh test`, or `Scripts/verify.sh run` with Xcode and a selected booted simulator. The default destination is the existing iPhone Duo; set `HARKLIGHT_SIMULATOR_ID` to use an iPad or another simulator for product validation. `run` installs and launches on that destination and saves a CoreSimulator screenshot. Desktop-window screenshots use Xcode Device Hub. Follow the repository [Harklight guidance](HARKLIGHT_GUIDANCE.md) for tests and gates.
