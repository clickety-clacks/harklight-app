# Harklight client repository instructions

Read [HARKLIGHT_GUIDANCE.md](HARKLIGHT_GUIDANCE.md) before adding, changing, or reviewing tests and gates in this repository. Apply its Harklight-scoped criterion to active checks; retain historical test reports as evidence of the source that produced them.

## Main-based development

`main` is the only long-lived branch. Everything is built on it, and every release is tagged from it.

- Work on a short-lived branch cut from current `main`. Merge it back within a day or two through a pull request. If a change can't land that quickly, make it smaller, or land it behind a feature flag (below). Never keep it on a long-running branch.
- Keep `main` releasable at every commit. A pull request merges only when CI passes and an independent reviewer who didn't write it has reviewed it clean.
- Rebase or merge `main` into your branch often, so it never drifts far from `main`.
- Delete the branch when it merges.
- Don't create release, candidate, integration or notes branches. A release is a tag on a `main` commit, and its release notes land on `main` like any other change.
- If `main` breaks, fixing it comes before any other work. Revert first when that's the fastest way back to green.

## Builds and releases

- Every merge to `main` triggers an Xcode Cloud build that goes to internal TestFlight automatically. There is nothing to start and nothing to approve. Agents never start Xcode Cloud workflows by hand.
- "Release through CI with no human approval" means this build path only: the Xcode Cloud internal TestFlight build on every merge to `main`. App Store or external TestFlight distribution is a separate step outside this process and needs its own existing authority; this document grants none.
- If a shipped build is bad, ship a fix or revert from `main` as the next build. Don't hand-patch a build.

## Large features behind a feature flag

A feature too big for one short-lived branch lands on `main` in small, reviewed slices, hidden behind a flag until it is ready.

- **Off by default.** A new flag ships off, so `main` and every build behave exactly as before until the flag is turned on.
- **One flag per feature.** A feature that seems to need many flags is usually better split into smaller features.
- **The old path keeps working.** While the flag is off, existing behavior must be unchanged and still covered by the checks. Test both the on and off states of anything the flag touches.
- **Recorded.** Every flag has a row in the register below: name, owner, default, and removal condition.
- **Turning it on is a reviewed change.** Making a flag default to on is its own small pull request.
- **Removal is part of the feature.** Once the feature is accepted, delete the flag, the off path and its tests in a follow-up pull request, and remove its register row. The feature isn't done until its flag is gone.
- Flags are for unfinished features. Don't use them for per-user settings or permanent configuration.

The server owns the remote flag configuration; this section only describes how the app reads flags. Remote flag values arrive from the server in the resynced frame on connect, under `resynced.feature_flags`. When a flag is absent from that frame, the app uses its built-in default.

### Feature-flag register

Add a row when you add a flag, update it when the default changes, and delete the row in the pull request that removes the flag.

| Flag | Owner | Default | Remove when |
| --- | --- | --- | --- |
| _none yet_ (example: `exampleFeature`) | the session or person accountable for the feature | off | the feature is accepted in a shipped build; delete the flag, its off path and tests |

## Project generation

- The Xcode project is generated from `project.yml` with XcodeGen. Use version 2.45.4 locally. This is a convention, not an enforced pin: CI currently runs an unpinned `brew install xcodegen` in all three jobs, so CI and local versions can drift.
- When you add or remove source files, regenerate and commit `Harklight.xcodeproj` in the same change.
- `Scripts/verify.sh` is the test wrapper: `Scripts/verify.sh build` and `Scripts/verify.sh test`. It runs `xcodegen generate` itself.

## CI and release

Keep each change small and reviewable, and merge to `main` promptly while the app remains usable. Do not hold a targeted fix behind unrelated unfinished work unless they are genuinely coupled. CI is required to build and test every PR/change and integrated `main`; fix or revert a red `main` promptly before stacking more work on it. Tests and gates must directly establish product business logic or specification, as [HARKLIGHT_GUIDANCE.md](HARKLIGHT_GUIDANCE.md) requires.

The existing local verification path is `Scripts/verify.sh build` and `Scripts/verify.sh test` with Xcode, XcodeGen and an eligible iOS simulator. The test action prepares its TLS fixture and runs the Harklight scheme; `HARKLIGHT_ONLY_TESTING` narrows the run and is not full-suite evidence. The checked-in Xcode Cloud post-clone hook handles build provenance and nonblocking archive release-note warnings; it does not establish PR/main build-and-test coverage. Distinguish configured workflow actions and actual run results from the coverage required above, and report missing coverage to the CI owner.

When a change needs a temporary release flag, keep unfinished behavior off by default. The flag must stop the actual behavior, including background work and any associated server endpoints, not merely hide controls. Check both production settings with the flag off and the next intended settings with it on. This is a requirement for flagged changes, not a claim that a general flag framework already exists; do not add one speculatively.

Deploy or distribute passing builds independently of feature readiness, within the existing release authority; enable a feature separately after its checks pass. Remove temporary flags and their obsolete conditional code after rollout. Flags must never hide compilation or startup failures, incompatible migrations, or broken shared dependencies: fix those failures before treating a build as releasable.
