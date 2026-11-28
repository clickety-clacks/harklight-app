#!/bin/bash
set -euo pipefail

# Run on two disposable, already enrolled simulators. Each must still hold the
# predecessor's app and data after the fixture's supported Server upgrade.
# The normal test wrapper installs the candidate over that same app container.
if [[ $# != 4 || "$1" == "$2" ]]; then
    printf 'Usage: %s <enrolled-iphone-udid> <enrolled-ipad-udid> <fixture-manifest.json> <candidate-commit>\n' "$0" >&2
    exit 2
fi

: "${HARKLIGHT_HISTORY_PREDECESSOR_BUILD:?Set the released predecessor App build number}"
: "${HARKLIGHT_HISTORY_PREDECESSOR_BUNDLE_BUILD:?Set the CFBundleVersion of the installed predecessor source rebuild}"
: "${HARKLIGHT_HISTORY_PREDECESSOR_VERSION:?Set the predecessor App marketing version}"
: "${HARKLIGHT_HISTORY_PREDECESSOR_COMMIT:?Set the verified predecessor App source commit}"
: "${HARKLIGHT_HISTORY_RESULTS:?Set a new directory for the platform result files}"

root=$(cd "$(dirname "$0")/.." && pwd -P)
candidate=$(git -C "$root" rev-parse HEAD)
if [[ ! "$4" =~ ^[a-f0-9]{40}$ || "$candidate" != "$4" ]]; then
    printf 'The checkout must match the full App release candidate commit.\n' >&2
    exit 2
fi

# Bind results to the exact input tree, not only HEAD. A test-only overlay
# (UI tests or this check's own script) is allowed and recorded; any other
# difference from the candidate commit, including the wrapper, is refused.
working_tree() {
    local index tree
    index=$(mktemp) || return 1
    rm -f "$index"
    GIT_INDEX_FILE="$index" git -C "$root" read-tree "$candidate^{tree}" || { rm -f "$index"; return 1; }
    GIT_INDEX_FILE="$index" git -C "$root" add -A || { rm -f "$index"; return 1; }
    tree=$(GIT_INDEX_FILE="$index" git -C "$root" write-tree) || { rm -f "$index"; return 1; }
    rm -f "$index"
    [[ "$tree" =~ ^[a-f0-9]{40}$ ]] || return 1
    printf '%s\n' "$tree"
}
if ! candidate_tree=$(working_tree); then
    printf 'Could not record the exact input tree.\n' >&2
    exit 2
fi
# --no-renames reports both sides of a move, so removing production source by
# moving it into UITests/ is still refused. Ignored files (build output and
# generated test credentials) are not part of the recorded tree.
overlay_list=$(mktemp)
if ! git -C "$root" diff --no-renames --name-only -z "$candidate^{tree}" "$candidate_tree" > "$overlay_list"; then
    rm -f "$overlay_list"
    printf 'Could not list differences from the candidate commit.\n' >&2
    exit 2
fi
overlay_paths=()
while IFS= read -r -d '' path; do
    overlay_paths+=("$path")
    case "$path" in
        Scripts/verify.sh) ;;
        UITests/*|Scripts/verify-history-upgrade.sh)
            if [[ -L "$root/$path" ]]; then
                printf 'A symbolic link may not be part of the test overlay: %s\n' "$path" >&2
                exit 2
            fi
            continue ;;
    esac
    printf 'Only a test-only overlay may differ from the candidate commit; found %s\n' "$path" >&2
    exit 2
done < "$overlay_list"
rm -f "$overlay_list"
export HARKLIGHT_HISTORY_CANDIDATE_TREE="$candidate_tree"
HARKLIGHT_HISTORY_OVERLAY_PATHS=$(printf '%s\n' "${overlay_paths[@]+"${overlay_paths[@]}"}")
export HARKLIGHT_HISTORY_OVERLAY_PATHS

fixture=$(python3 - "$3" <<'PYTHON'
import json
import re
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
version = manifest["server_version"]
commit = manifest["server_commit"]
digest = manifest["fixture_sha256"]
upgrade = manifest["upgrade"]
expected = manifest["expected"]

if not re.fullmatch(r"[a-f0-9]{40}", commit):
    raise SystemExit("Invalid Server commit in fixture manifest")
if not re.fullmatch(r"[a-f0-9]{64}", digest):
    raise SystemExit("Invalid fixture digest in fixture manifest")
if len(upgrade) < 2 or upgrade[-1] != version:
    raise SystemExit("Fixture upgrade path must end at the target Server version")

fields = [
    version, commit, digest, " -> ".join(upgrade),
    expected["unanswered_item"], expected["answered_item"],
    expected["discussion_item"], expected["answer"],
    expected["discussion_entry"], expected["discussion"],
]
if not all(isinstance(field, str) and field and field.isprintable() for field in fields):
    raise SystemExit("Fixture observations must be nonempty single-line text")
print(*fields, sep="\n")
PYTHON
)
{
    IFS= read -r HARKLIGHT_HISTORY_SERVER_VERSION
    IFS= read -r HARKLIGHT_HISTORY_SERVER_COMMIT
    IFS= read -r HARKLIGHT_HISTORY_FIXTURE_SHA256
    IFS= read -r HARKLIGHT_HISTORY_SERVER_UPGRADE
    IFS= read -r HARKLIGHT_DIAGNOSTIC_HISTORY_UNANSWERED_ID
    IFS= read -r HARKLIGHT_DIAGNOSTIC_HISTORY_ANSWERED_ID
    IFS= read -r HARKLIGHT_DIAGNOSTIC_HISTORY_DISCUSSED_ID
    IFS= read -r HARKLIGHT_HISTORY_ANSWER
    IFS= read -r HARKLIGHT_HISTORY_DISCUSSION_ENTRY
    IFS= read -r HARKLIGHT_HISTORY_DISCUSSION
} <<< "$fixture"
export HARKLIGHT_HISTORY_SERVER_VERSION HARKLIGHT_HISTORY_SERVER_COMMIT HARKLIGHT_HISTORY_FIXTURE_SHA256
if [[ ${HARKLIGHT_ISOLATED_UI_DIAGNOSTIC:-} != 1 ]]; then
    printf 'An approved isolated Server, account, and simulator pair are required.\n' >&2
    exit 2
fi

for scenario in UNANSWERED ANSWERED DISCUSSED; do
    for field in ID TITLE; do
        key="HARKLIGHT_DIAGNOSTIC_HISTORY_${scenario}_${field}"
        if [[ -z ${!key:-} ]]; then
            printf 'Missing pre-upgrade inventory field %s\n' "$key" >&2
            exit 2
        fi
        export "TEST_RUNNER_${key}=${!key}"
    done
done

devices=$(xcrun simctl list devices available -j)
export TEST_RUNNER_HARKLIGHT_ISOLATED_UI_DIAGNOSTIC=1
export TEST_RUNNER_HARKLIGHT_HISTORY_RELEASE_CHECK=1
export TEST_RUNNER_HARKLIGHT_HISTORY_ANSWER="$HARKLIGHT_HISTORY_ANSWER"
export TEST_RUNNER_HARKLIGHT_HISTORY_DISCUSSION="$HARKLIGHT_HISTORY_DISCUSSION"
export TEST_RUNNER_HARKLIGHT_HISTORY_DISCUSSION_ENTRY="$HARKLIGHT_HISTORY_DISCUSSION_ENTRY"
test_name=testPreUpgradeMessagesAndHistoryRemainVisible
export HARKLIGHT_ONLY_TESTING="HarklightUITests/TwoDeviceServerCacheUITests/$test_name"

results_parent=$(cd "$(dirname "$HARKLIGHT_HISTORY_RESULTS")" && pwd -P) || exit 2
case "$results_parent/" in
    "$root"/*) printf 'Write results outside the checkout so the input tree stays exact.\n' >&2; exit 2 ;;
esac
mkdir "$HARKLIGHT_HISTORY_RESULTS"

verify_device() {
    local device="$1" form_factor="$2" logfile app_path installed_build installed_version candidate_build candidate_version
    python3 -c '
import json, sys
device_id, family = sys.argv[1:]
devices = json.load(sys.stdin)["devices"]
matches = [device for runtime in devices.values() for device in runtime
           if device["udid"] == device_id and device.get("isAvailable")
           and device.get("deviceTypeIdentifier", "").startswith(
               "com.apple.CoreSimulator.SimDeviceType." + family)]
if len(matches) != 1:
    sys.exit("Expected an available " + family + " simulator for " + device_id)
' "$device" "$form_factor" <<< "$devices"

    # A missing predecessor must never silently become a clean-install check.
    xcrun simctl bootstatus "$device" -b
    app_path=$(xcrun simctl get_app_container "$device" co.clicketyclacks.Harklight app)
    installed_build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app_path/Info.plist")
    installed_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app_path/Info.plist")
    if [[ "$installed_build" != "$HARKLIGHT_HISTORY_PREDECESSOR_BUNDLE_BUILD" ||
          "$installed_version" != "$HARKLIGHT_HISTORY_PREDECESSOR_VERSION" ]]; then
        printf '%s has %s (%s); expected predecessor rebuild %s (%s)\n' \
            "$form_factor" "$installed_version" "$installed_build" \
            "$HARKLIGHT_HISTORY_PREDECESSOR_VERSION" "$HARKLIGHT_HISTORY_PREDECESSOR_BUNDLE_BUILD" >&2
        return 1
    fi
    logfile="$HARKLIGHT_HISTORY_RESULTS/$form_factor.xctest.log"
    printf '%s predecessor=%s candidate=%s server=%s\n' \
        "$form_factor" "$HARKLIGHT_HISTORY_PREDECESSOR_BUILD/$HARKLIGHT_HISTORY_PREDECESSOR_COMMIT" \
        "$candidate" "$HARKLIGHT_HISTORY_SERVER_UPGRADE"
    if ! HARKLIGHT_SIMULATOR_ID="$device" "$root/Scripts/verify.sh" test | tee "$logfile" ||
        ! grep -Eq "Test Case .*${test_name}.* passed" "$logfile"; then
        printf '%s history check did not pass\n' "$form_factor" >&2
        return 1
    fi
    app_path=$(xcrun simctl get_app_container "$device" co.clicketyclacks.Harklight app)
    candidate_build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app_path/Info.plist")
    candidate_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app_path/Info.plist")
    xcrun simctl shutdown "$device"
    local now_tree
    if ! now_tree=$(working_tree) || [[ "$now_tree" != "$candidate_tree" ]]; then
        printf 'The checkout changed during the %s check\n' "$form_factor" >&2
        return 1
    fi
    python3 - "$form_factor" "$candidate_version ($candidate_build) source $candidate" "$candidate" > "$HARKLIGHT_HISTORY_RESULTS/$form_factor.json" <<'PYTHON'
import json
import os
import sys

platform, client_build, client_commit = sys.argv[1:]

def item_id(scenario):
    return os.environ["TEST_RUNNER_HARKLIGHT_DIAGNOSTIC_HISTORY_" + scenario + "_ID"]

json.dump({
    "platform": platform,
    "client_build": client_build,
    "client_commit": client_commit,
    "client_tree": os.environ["HARKLIGHT_HISTORY_CANDIDATE_TREE"],
    "test_overlay_paths": [p for p in os.environ["HARKLIGHT_HISTORY_OVERLAY_PATHS"].splitlines() if p],
    "server_version": os.environ["HARKLIGHT_HISTORY_SERVER_VERSION"],
    "server_commit": os.environ["HARKLIGHT_HISTORY_SERVER_COMMIT"],
    "fixture_sha256": os.environ["HARKLIGHT_HISTORY_FIXTURE_SHA256"],
    "outcome": "pass",
    "observations": {
        "unanswered_item": item_id("UNANSWERED"),
        "answered_item": item_id("ANSWERED"),
        "answer": os.environ["TEST_RUNNER_HARKLIGHT_HISTORY_ANSWER"],
        "discussion_item": item_id("DISCUSSED"),
        "discussion_entry": os.environ["TEST_RUNNER_HARKLIGHT_HISTORY_DISCUSSION_ENTRY"],
        "discussion": os.environ["TEST_RUNNER_HARKLIGHT_HISTORY_DISCUSSION"],
    },
    "relaunch": "pass",
}, sys.stdout, indent=2)
PYTHON
}

verify_device "$1" iPhone
verify_device "$2" iPad
