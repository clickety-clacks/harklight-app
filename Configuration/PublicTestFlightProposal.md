# Public TestFlight proposal

**Proposal only.** This file and the `Harklight-PublicTestFlight` scheme do not create or enable an Xcode Cloud workflow, upload a build, submit a build for beta review, create a tester group, or publish a public link.

## Source path

Use a dedicated `public-testflight` branch and the `Harklight-PublicTestFlight` scheme. Its `PublicTestFlight` archive configuration keeps the existing app bundle identifier and sets `CFBundleVersion` from Xcode Cloud's `CI_BUILD_NUMBER`. The app target keeps the project's iOS 27.0 deployment target. For this scheme, the post-clone script records the exact source commit and tree in the app bundle and checks release-note readiness before an archive starts.

The existing `Harklight` scheme and its `Release` archive configuration remain the internal path. Its existing post-clone behavior stays in place; the strict release-note gate is called only for `Harklight-PublicTestFlight`. The proposed external workflow is separate from the internal scheme and configuration.

## Proposed Xcode Cloud workflow

After a separate decision to activate it, create an Xcode Cloud workflow with a start condition limited to `public-testflight`, select `Harklight-PublicTestFlight`, run the test action, then archive with **TestFlight and App Store** deployment preparation. Apple describes this choice as preparing an archive eligible for TestFlight external testing and App Store distribution. Add a TestFlight distribution post-action for the external testing group after that group exists. External testing is subject to TestFlight App Review; testing can begin after approval, with tester notification sent automatically if configured or manually through App Store Connect. Keep the existing internal workflow's scheme and deployment setting unchanged.

The archive's bundle version is the Cloud build number. Before the first upload, the Cloud build-number sequence must be confirmed to exceed any existing uploaded build for the app version. That App Store Connect value was not inspected, so the first public build number and its upload eligibility remain unconfirmed. The embedded provenance resource records the exact commit and source tree from the same archive, so the bundle version can be paired with its source. A missing or mismatched source revision fails the archive before distribution.

## External testing and public-link boundary

An eligible archive or upload does not make the app available to external testers. App Store Connect needs an internal testing group before an external group can be created. The first build submitted to an external group receives a full TestFlight App Review; later builds may not require a full review. A build must be approved before testing can begin.

Creating or enabling a public link is a separate App Store Connect action after an approved build is available to an external group. That link can be shared by anyone who receives it. App Store Connect supports device or OS criteria and a tester limit; the link can also be disabled. Keep the link out of source control and do not activate it as part of this proposal.

## Release-note gate

For `Harklight-PublicTestFlight`, the post-clone check runs for Xcode Cloud archive actions only, after the source checkout and before the archive action. It requires each app-source change since the reviewed baseline to update `Sources/ReleaseNotes.swift` or carry a `Release-Notes: none - <reason>` commit trailer. It skips pull requests and build/test actions. The existing internal workflow keeps its base post-clone behavior, so missing notes stop a public distribution archive without holding normal merges or internal builds.

Release-note claims still need source-level verification. Unknown historical build numbers are shown as `UNCONFIRMED`; no number is inferred from the current checkout. Add notes for sibling-lane behavior only after that behavior is integrated and confirmed.

## Still unexercised

This proposal has not been connected to Xcode Cloud or App Store Connect. The remote branch trigger, archive and external-distribution post-actions, first build-number uniqueness, Cloud signing and upload eligibility, App Store Connect processing, external-group creation, beta-review outcome, tester notification, and public-link creation or activation all require Apple-side actions and remain unverified here.

Apple references:

- [Configuring an Xcode Cloud workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
- [Creating a workflow that builds your app for distribution](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution)
- [Xcode Cloud environment variables](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Xcode build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
