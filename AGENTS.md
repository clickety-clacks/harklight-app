# Harklight client repository instructions

Read [HARKLIGHT_GUIDANCE.md](HARKLIGHT_GUIDANCE.md) before adding, changing, or reviewing tests and gates in this repository. Apply its Harklight-scoped criterion to active checks; retain historical test reports as evidence of the source that produced them.

## Main-based development

`main` is the only long-lived branch. Everything is built on it, and every release is tagged from it.

- Work on a short-lived branch cut from current `main`. Merge it back within a day or two through a pull request. If a change can't land that quickly, make it smaller, or land it behind a feature flag (below). Never keep it on a long-running branch.
- Keep `main` releasable at every commit. A pull request merges to `main` when its checks show no failure that `main` doesn't already have. Don't hold it for review: independent review by someone who didn't write it runs alongside the work, and any finding gets fixed in a follow-up pull request. Hold work back only when the next step would be hard to undo or would reach real users.
- Where hosted CI is queued and not running, an exact-head local build plus focused tests through `Scripts/verify.sh` stands in for it. A job that runs and fails on something new blocks the merge.
- Rebase or merge `main` into your branch often, so it never drifts far from `main`.
- Delete the branch when it merges.
- Don't create release, candidate, integration or notes branches. A release is a tag on a `main` commit, and its release notes land on `main` like any other change.
- If `main` breaks, fixing it comes before any other work. Revert first when that's the fastest way back to green.

## Builds and releases

- Every merge to `main` triggers an Xcode Cloud build that goes to internal TestFlight automatically. There is nothing to start and nothing to approve. Agents never start Xcode Cloud workflows by hand.
- Internal TestFlight builds, made automatically on every merge to `main`, follow the owner's ship-to-me rule and are not a release. A release for this app means App Store or public/external TestFlight distribution. It is a separate step outside the automatic build path and needs its own existing authority; this document grants none. Every change in a release must have a clean independent review before that release is tagged.
- If a shipped build is bad, ship a fix or revert from `main` as the next build. Don't hand-patch a build.

## Large features behind a feature flag

A feature too big for one short-lived branch lands on `main` in small, reviewed slices, hidden behind a flag until it is ready.

- **Off by default.** A new flag ships off, so `main` and every build behave exactly as before until the flag is turned on.
- **One flag per feature.** A feature that seems to need many flags is usually better split into smaller features.
- **The old path keeps working.** While the flag is off, existing behavior must be unchanged and still covered by the checks. Test both the on and off states of anything the flag touches.
- **Off means the previous behavior, never missing content.** A flag turned off restores the old behavior; it never hides data. For example, with `progress_inbox` off, Progress messages appear as ordinary messages in the normal list.
- **Recorded.** Every flag has a row in the register below: name, owner, default, and removal condition.
- **Turning it on is a reviewed change.** Making a flag default to on is its own small pull request.
- **Removal is part of the feature.** Once the feature is accepted, delete the flag, the off path and its tests in a follow-up pull request, and remove its register row. The feature isn't done until its flag is gone.
- Flags are for unfinished features. Don't use them for per-user settings or permanent configuration.

The server owns the remote flag configuration; this section only describes how the app reads flags. Remote flag values arrive from the server in the resynced frame on connect, under `resynced.feature_flags`. When a flag is absent from that frame, the app uses its built-in default.

### Feature-flag register

Add a row when you add a flag, update it when the default changes, and delete the row in the pull request that removes the flag.

| Flag | Owner | Default | Remove when |
| --- | --- | --- | --- |
| `progress_inbox` | Client PO and the Progress feature owner | **on** (recorded exception: Progress was requested, is reviewed and merged in #293, and the server has no flag support yet, so default-off would hide it with no way to turn it on) | the Progress list and detail behavior is accepted |
| `server_matched_push_routing` | Client PO and the push-routing feature owner | off | notification routing and the account-departure behavior (#292) are accepted |
| `priority_level_editing` | Client PO and the priority-levels feature owner | off | native read and save of priority levels (#203) are accepted |

## Project generation

- The Xcode project is generated from `project.yml` with XcodeGen. Use version 2.45.4 locally. This is a convention, not an enforced pin: CI currently runs an unpinned `brew install xcodegen` in all three jobs, so CI and local versions can drift.
- When you add or remove source files, regenerate and commit `Harklight.xcodeproj` in the same change.
- `Scripts/verify.sh` is the test wrapper: `Scripts/verify.sh build` and `Scripts/verify.sh test`. It runs `xcodegen generate` itself.

## CI and release

Keep each change small and reviewable, and merge to `main` promptly while the app remains usable. Do not hold a targeted fix behind unrelated unfinished work unless they are genuinely coupled. CI is required to build and test every PR/change and integrated `main`; fix or revert a red `main` promptly before stacking more work on it. Tests and gates must directly establish product business logic or specification, as [HARKLIGHT_GUIDANCE.md](HARKLIGHT_GUIDANCE.md) requires.

The existing local verification path is `Scripts/verify.sh build` and `Scripts/verify.sh test` with Xcode, XcodeGen and an eligible iOS simulator. The test action prepares its TLS fixture and runs the Harklight scheme; `HARKLIGHT_ONLY_TESTING` narrows the run and is not full-suite evidence. The checked-in Xcode Cloud post-clone hook handles build provenance and nonblocking archive release-note warnings; it does not establish PR/main build-and-test coverage. Distinguish configured workflow actions and actual run results from the coverage required above, and report missing coverage to the CI owner.

When a change needs a temporary release flag, keep unfinished behavior off by default. The flag must stop the actual behavior, including background work and any associated server endpoints, not merely hide controls. Check both production settings with the flag off and the next intended settings with it on. This is a requirement for flagged changes, not a claim that a general flag framework already exists; do not add one speculatively.

Deploy or distribute passing builds independently of feature readiness, within the existing release authority; enable a feature separately after its checks pass. Remove temporary flags and their obsolete conditional code after rollout. Flags must never hide compilation or startup failures, incompatible migrations, or broken shared dependencies: fix those failures before treating a build as releasable.
