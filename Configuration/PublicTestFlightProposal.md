# Public TestFlight proposal

**Proposal only.** This document describes a possible source and workflow path. It does not add a scheme or build configuration, change CI scripts, enable Xcode Cloud, create a build, upload or submit an archive, create a tester group, or activate a public link.

## Proposed source and build path

Keep the existing internal `Harklight` scheme, `Release` configuration, and warning-only post-clone behavior as the internal path. If a public beta is approved, use a dedicated `public-testflight` branch with a separate Cloud branch trigger and, as future source configuration, a dedicated scheme and release configuration. Those future pieces should retain the existing app bundle identifier and the project's iOS 27.0 deployment target. The archive's `CFBundleVersion` could come from Xcode Cloud's `CI_BUILD_NUMBER`; confirm that the first value is higher than any already-uploaded build for the selected marketing version before creating an archive.

In Xcode Cloud, choose **TestFlight and App Store** as the archive's distribution preparation. Apple documents this as preparing an archive eligible for TestFlight external testing and App Store distribution. The archive can be uploaded only after a separate decision to activate the workflow; the uploaded build still needs App Store Connect processing and beta review before external testing can begin.

## Workflow and tester boundaries

After approval, configure a workflow triggered only from `public-testflight`, run the test action, archive using the dedicated release configuration, and add an external TestFlight distribution post-action after its external group exists. Keep the internal workflow on its current scheme and configuration.

An internal testing group must exist before an external group can be created. External testing is subject to TestFlight App Review; the first build submitted to an external group receives a full review, while later builds may not. A public link is a separate App Store Connect action for an approved build in an external group. Anyone with the link can share it, and App Store Connect supports device or OS criteria, a tester limit, and link disabling. Do not put the link in source control.

## Release-note readiness

Keep release notes with the source and preserve confirmed build-to-source associations. Mark unknown build numbers `UNCONFIRMED`. The current release policy requires notes to be ready without holding normal merges or builds, so this proposal includes no blocking release-note gate.

If a blocking history check is considered separately in the future, it needs an explicit product decision and a design that respects that policy. An ancestry check against a fixed baseline fails on shallow clones; requiring a note or trailer on every source change also rejects existing commits without trailers. Those cases need a supported path before such a check could be evaluated. Sibling-lane notes should be added only after their changes are integrated and verified.

## Still unexercised

This proposal has not been connected to Xcode Cloud or App Store Connect. The remote branch trigger, archive and external-distribution actions, first build-number uniqueness, Cloud signing and upload eligibility, App Store Connect processing, external-group creation, beta-review outcome, tester notification, and public-link creation or activation all require Apple-side actions and remain unverified here.

Apple references:

- [Configuring an Xcode Cloud workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)
- [Creating a workflow that builds your app for distribution](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution)
- [Xcode Cloud environment variables](https://developer.apple.com/documentation/xcode/environment-variable-reference)
- [Xcode build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
- [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
- [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)
