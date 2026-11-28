# Release check: old messages still show after an upgrade

Every Harklight release must show that messages a person already had before
the upgrade still appear in the clients afterwards, together with their answers
and chat history. A new message sent after the upgrade, or a Server-side storage
check, does not satisfy this.

## Where it runs

The check is part of the Harklight Server release gate. A Server release
candidate is not promoted until the gate has passing iPhone, iPad and Web
results for that exact candidate, all against the same upgraded fixture.

The App also needs this result before an App build is offered beyond Internal
TestFlight to people who already use an earlier build. The check uses the
current Server release candidate, or the latest released Server if none is
pending.

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
wrapper. The Server release gate accepts the App half only when both files
match its candidate, fixture and expected messages.
