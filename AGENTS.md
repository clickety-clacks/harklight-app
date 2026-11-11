# Harklight client repository instructions

Read [HARKLIGHT_GUIDANCE.md](HARKLIGHT_GUIDANCE.md) before adding, changing, or reviewing tests and gates in this repository. Apply its Harklight-scoped criterion to active checks; retain historical test reports as evidence of the source that produced them.

## CI and release

Keep each change small and reviewable, and merge to `main` promptly while the app remains usable. Do not hold a targeted fix behind unrelated unfinished work unless they are genuinely coupled. CI is required to build and test every PR/change and integrated `main`; fix or revert a red `main` promptly before stacking more work on it. Tests and gates must directly establish product business logic or specification, as [HARKLIGHT_GUIDANCE.md](HARKLIGHT_GUIDANCE.md) requires.

The existing local verification path is `Scripts/verify.sh build` and `Scripts/verify.sh test` with Xcode, XcodeGen and an eligible iOS simulator. The test action prepares its TLS fixture and runs the Harklight scheme; `HARKLIGHT_ONLY_TESTING` narrows the run and is not full-suite evidence. The checked-in Xcode Cloud post-clone hook handles build provenance and nonblocking archive release-note warnings; it does not establish PR/main build-and-test coverage. Distinguish configured workflow actions and actual run results from the coverage required above, and report missing coverage to the CI owner.

When a change needs a temporary release flag, keep unfinished behavior off by default. The flag must stop the actual behavior, including background work and any associated server endpoints, not merely hide controls. Check both production settings with the flag off and the next intended settings with it on. This is a requirement for flagged changes, not a claim that a general flag framework already exists; do not add one speculatively.

Deploy or distribute passing builds independently of feature readiness, within the existing release authority; enable a feature separately after its checks pass. Remove temporary flags and their obsolete conditional code after rollout. Flags must never hide compilation or startup failures, incompatible migrations, or broken shared dependencies: fix those failures before treating a build as releasable.
