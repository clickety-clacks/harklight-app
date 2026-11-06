#!/bin/sh
set -eu

fail() {
    printf '%s\n' "$1" >&2
    exit 2
}

APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SERVER_ROOT=${HARKLIGHT_SERVER_CHECKOUT:-}
[ -n "$SERVER_ROOT" ] || fail "Set HARKLIGHT_SERVER_CHECKOUT to the isolated Harklight Server 0.1.26 checkout."
[ "$(git -C "$SERVER_ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || fail "HARKLIGHT_SERVER_CHECKOUT is not a Git checkout."
SERVER_SOURCE_COMMIT=f7a002600f8e03fbfe8c766266ac6a7f2ab2b500
if ! git -C "$SERVER_ROOT" merge-base --is-ancestor "$SERVER_SOURCE_COMMIT" HEAD; then
    fail "The producer checkout must contain Server 0.1.26 source commit $SERVER_SOURCE_COMMIT."
fi
[ -z "$(git -C "$SERVER_ROOT" status --porcelain)" ] || fail "The server producer checkout must be clean and pinned before this evidence run."
grep -q 'version: "0.1.26"' "$SERVER_ROOT/mix.exs" || fail "The server checkout is not version 0.1.26."

PRODUCER_COMMIT=$(git -C "$SERVER_ROOT" rev-parse HEAD)
APP_SOURCE_COMMIT=$(git -C "$APP_ROOT" rev-parse HEAD)
RUN_ROOT=${HARKLIGHT_RETRACTION_EVIDENCE_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/harklight-retraction-evidence.XXXXXX")}
mkdir -p "$RUN_ROOT"
FIXTURE_ROOT="$RUN_ROOT/server-fixture"
mkdir -p "$FIXTURE_ROOT"
READY="$FIXTURE_ROOT/ready.json"
MARKER="$FIXTURE_ROOT/completed.json"
SERVER_LOG="$RUN_ROOT/server-producer.log"
APP_LOG="$RUN_ROOT/native-app-test.log"
RESOURCE="$APP_ROOT/Resources/native-server-retraction.json"
RESOURCE_INSTALLED=0
SERVER_PID=

[ ! -e "$RESOURCE" ] || fail "Refusing to overwrite existing Resources/native-server-retraction.json."

cleanup() {
    status=$?
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [ "$RESOURCE_INSTALLED" -eq 1 ]; then
        rm -f "$RESOURCE"
    fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

python3 - "$RUN_ROOT/run-metadata.json" "$APP_SOURCE_COMMIT" "$SERVER_SOURCE_COMMIT" "$PRODUCER_COMMIT" <<'PY'
import json, sys
path, app, server, producer = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"app_commit": app, "server_source_commit": server,
               "producer_commit": producer, "server_version": "0.1.26"}, f,
              indent=2, sort_keys=True)
    f.write("\n")
PY

(
    cd "$SERVER_ROOT"
    HARKLIGHT_INTEROP_DIR="$FIXTURE_ROOT" \
    HARKLIGHT_INTEROP_SERVER_COMMIT="$SERVER_SOURCE_COMMIT" \
    HARKLIGHT_INTEROP_PRODUCER_COMMIT="$PRODUCER_COMMIT" \
    HARKLIGHT_INTEROP_MODE=retraction_native \
    mix test test/interop/conversation_native_fixture.exs
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

attempt=0
while [ ! -s "$READY" ]; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        cat "$SERVER_LOG" >&2
        fail "The isolated server producer ended before it emitted its native retraction fixture. Evidence: $RUN_ROOT"
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 2400 ]; then
        cat "$SERVER_LOG" >&2
        fail "Timed out waiting for the isolated server producer. Evidence: $RUN_ROOT"
    fi
    sleep 0.25
done
cp "$READY" "$RUN_ROOT/server-ready.json"
cp "$READY" "$RESOURCE"
RESOURCE_INSTALLED=1

if [ -z "${HARKLIGHT_SIMULATOR_ID:-}" ]; then
    HARKLIGHT_SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    version = re.search(r"iOS-(\d+)(?:-|$)", runtime)
    if version and int(version.group(1)) >= 27:
        devices.extend(device for device in entries if device.get("isAvailable"))
devices.sort(key=lambda device: device.get("state") != "Booted")
if not devices:
    sys.exit("No available iOS 27 or newer simulator can run this app.")
print(devices[0]["udid"])
')
fi
export HARKLIGHT_SIMULATOR_ID

if ! HARKLIGHT_ONLY_TESTING="HarklightUITests/RetractionExpiryRelaunchUITests/testServerRetractionExpiresInForegroundAndAfterProcessRelaunch HarklightTests/RetractionPresentationTests/testRetractionExpiryUsesItsTimestampAndKeepsRowsWithoutOne HarklightTests/RetractionPresentationTests/testClearingARetractedRowIsDeviceLocalListStateOnly HarklightTests/RetractionPresentationTests/testRetractionJoinsBothDurableOrdersWithoutRewritingQueuedBindingsOrReopening" \
    "$APP_ROOT/Scripts/verify.sh" test >"$APP_LOG" 2>&1; then
    cat "$APP_LOG" >&2
    fail "The focused native-app retraction test failed. Evidence: $RUN_ROOT"
fi

python3 - "$READY" "$MARKER" <<'PY'
import json, os, sys
ready_path, marker_path = sys.argv[1:]
with open(ready_path, encoding="utf-8") as f:
    ready = json.load(f)
marker = {"fixture_id": ready["fixture_id"], "status": "passed",
          "wrapper_exit_status": 0,
          "retracted_at_ms": ready["native_retraction"]["retracted_at_ms"]}
tmp = marker_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(marker, f, sort_keys=True)
    f.write("\n")
os.replace(tmp, marker_path)
PY

if ! wait "$SERVER_PID"; then
    SERVER_PID=
    cat "$SERVER_LOG" >&2
    fail "The server producer's post-app preservation assertions failed. Evidence: $RUN_ROOT"
fi
SERVER_PID=
cp "$FIXTURE_ROOT/producer-result.json" "$RUN_ROOT/server-producer-result.json"

APP_DATA=$(xcrun simctl get_app_container "$HARKLIGHT_SIMULATOR_ID" co.clicketyclacks.Harklight data)
APP_SUPPORT="$APP_DATA/Library/Application Support/Attention"
[ -d "$APP_SUPPORT" ] || fail "The app's file-backed Attention store is missing after relaunch. Evidence: $RUN_ROOT"
[ -s "$APP_SUPPORT/native-server-retraction-readback.json" ] || fail "The app's persisted retraction readback is missing. Evidence: $RUN_ROOT"
mkdir -p "$RUN_ROOT/app-support"
cp -R "$APP_SUPPORT" "$RUN_ROOT/app-support/Attention"

LATEST_RESULT=$(ls -td "$APP_ROOT"/DerivedData/Logs/Test/*.xcresult 2>/dev/null | head -n 1 || true)
if [ -n "$LATEST_RESULT" ]; then
    ditto "$LATEST_RESULT" "$RUN_ROOT/Harklight-focused-test.xcresult"
fi

printf 'Evidence directory: %s\n' "$RUN_ROOT"
printf 'App source commit: %s\n' "$APP_SOURCE_COMMIT"
printf 'Server source commit: %s\n' "$SERVER_SOURCE_COMMIT"
printf 'Producer test commit: %s\n' "$PRODUCER_COMMIT"
printf 'Retraction timestamp: %s\n' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["retracted_at_ms"])' "$RUN_ROOT/server-producer-result.json")"
printf 'Focused app test: passed\nServer post-app preservation: passed\n'
