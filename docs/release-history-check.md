# Release check: old messages still show after an upgrade

Every Harklight release must show that messages a person already had before
the upgrade still appear in the clients afterwards, together with their answers
and chat history. A new message sent after the upgrade, or a Server-side storage
check, does not satisfy this.

## Where it runs

The check is part of the Harklight Server release gate. For every new Server
release published through the normal tagged build and publish path, the
publish workflow requires an accepted run for the exact candidate. It rejects
missing or mismatched iPhone, iPad and Web results from the same upgraded
fixture. See the Server repository's
[release publish workflow](https://github.com/clickety-clacks/harklight-server/blob/e3e40aa7ae652bf56e04396901ca58f568c085f0/.github/workflows/harklight-release-publish.yml#L50-L70)
and its
[history continuity guide](https://github.com/clickety-clacks/harklight-server/blob/e3e40aa7ae652bf56e04396901ca58f568c085f0/scripts/history-continuity/README.md#L60-L78).

Promoting an App build beyond Internal TestFlight to people who already use an
earlier build is a separate App release step. No workflow enforces it: the App
release owner runs this check and keeps the passing results before promoting.
The check uses the current Server release candidate, or the latest released
Server if none is pending.

## How the App half runs

1. Seed an isolated fixture on the predecessor Server release with one
   unanswered message, one answered message and one message with a chat.
2. On two fresh, disposable simulators (one iPhone, one iPad), install a source
   rebuild of the predecessor App build. Enroll each one and open those messages
   through the ordinary Inbox, Replied and Chat flows.
3. Upgrade the fixture through the supported Server upgrade path. The fixture
   owner provides a manifest with the Server version and commit, the fixture
   digest, the upgrade path and the expected messages.
4. Run:

   ```
   HARKLIGHT_ISOLATED_UI_DIAGNOSTIC=1 \
   HARKLIGHT_HISTORY_PREDECESSOR_BUILD=<build> \
   HARKLIGHT_HISTORY_PREDECESSOR_BUNDLE_BUILD=<CFBundleVersion> \
   HARKLIGHT_HISTORY_PREDECESSOR_VERSION=<version> \
   HARKLIGHT_HISTORY_PREDECESSOR_COMMIT=<commit> \
   HARKLIGHT_HISTORY_RESULTS=<new directory outside the checkout> \
   HARKLIGHT_DIAGNOSTIC_HISTORY_UNANSWERED_TITLE=<title of the unanswered message> \
   HARKLIGHT_DIAGNOSTIC_HISTORY_ANSWERED_TITLE=<title of the answered message> \
   HARKLIGHT_DIAGNOSTIC_HISTORY_DISCUSSED_TITLE=<title of the message with a chat> \
   Scripts/verify-history-upgrade.sh <iphone-udid> <ipad-udid> <manifest.json> <candidate-commit>
   ```

   The script installs the candidate over each predecessor app with the
   unchanged `Scripts/verify.sh`. It then finds and opens the same old messages,
   relaunches the app, and checks them again.

## Required result

The script writes `iPhone.json` and `iPad.json`, each with `"outcome": "pass"`.
They record the client build, the candidate commit and its exact input tree,
any test-only overlay paths, the Server version and commit, the fixture digest,
and the matched messages. The script refuses a checkout that differs from the
candidate commit outside `UITests/` or this script, including any change to the
wrapper, and refuses symbolic links in the overlay. Ignored files, such as build
output and generated test credentials, are not part of the recorded tree. The Server release gate accepts the App half only when both files match its
candidate, fixture and expected messages.
