#!/bin/sh
set -eu

fail() {
    printf '%s\n' "$1" >&2
    exit 2
}

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ACTION=${1:-test}
DEVICE_ID=${HARKLIGHT_SIMULATOR_ID:-}
BUNDLE_ID=co.clicketyclacks.Harklight

case "$ACTION" in
    build|test|test-guided-tls|run|host-test|host-run|native-host-test) ;;
    *) fail "Usage: Scripts/verify.sh [build|test|test-guided-tls|run|host-test|host-run|native-host-test]" ;;
esac

if [ "$ACTION" = native-host-test ]; then
    cd "$ROOT/NativeHost"
    xcrun swift test
    exec node --test TestsJS/*.test.js
fi
if [ "$ACTION" = host-test ] || [ "$ACTION" = host-run ]; then
    if [ "$ACTION" = host-test ]; then
        cd "$ROOT"
        python3 -m unittest discover -s HostFixture/tests -v
        exec node --test HostFixture/tests/test_app.js
    fi
    if [ -n "${ATTENTION_FIXTURE_PAIR_FILE:-}" ]; then
        if [ -n "${ATTENTION_FIXTURE_TRACE_FILE:-}" ]; then
            exec python3 "$ROOT/HostFixture/host.py" --port "${ATTENTION_FIXTURE_PORT:-0}" --pair-secret-file "$ATTENTION_FIXTURE_PAIR_FILE" --trace-file "$ATTENTION_FIXTURE_TRACE_FILE"
        fi
        exec python3 "$ROOT/HostFixture/host.py" --port "${ATTENTION_FIXTURE_PORT:-0}" --pair-secret-file "$ATTENTION_FIXTURE_PAIR_FILE"
    fi
    exec python3 "$ROOT/HostFixture/host.py" --port "${ATTENTION_FIXTURE_PORT:-0}"
fi
if [ "$ACTION" = test ] || [ "$ACTION" = test-guided-tls ]; then
    "$ROOT/Scripts/prepare-test-tls.sh"
fi
if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    version = re.search(r"iOS-(\d+)(?:-|$)", runtime)
    if version and int(version.group(1)) >= 27:
        devices.extend(device for device in entries if device.get("isAvailable"))
devices.sort(key=lambda device: device.get("state") != "Booted")
if not devices:
    sys.exit("No available iOS 27 or newer simulator can run this app. Set HARKLIGHT_SIMULATOR_ID to an eligible destination.")
print(devices[0]["udid"])
')
fi
(cd "$ROOT" && xcodegen generate)

PROJECT="$ROOT/Harklight.xcodeproj"
SCHEME=Harklight
DESTINATION="platform=iOS Simulator,id=$DEVICE_ID"
DERIVED_DATA="$ROOT/DerivedData"

case "$ACTION" in
    build)
        exec xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
            -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
        ;;
    test|test-guided-tls)
        set --
        if [ "$ACTION" = test-guided-tls ]; then
            set -- -only-testing:HarklightTests/NativeGuidedTLSTests
        elif [ -n "${HARKLIGHT_ONLY_TESTING:-}" ]; then
            for test_id in $HARKLIGHT_ONLY_TESTING; do
                set -- "$@" "-only-testing:$test_id"
            done
        fi
        exec xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
            -derivedDataPath "$DERIVED_DATA" -collect-test-diagnostics never CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- "$@" test
        ;;
    run)
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
            -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
        APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Harklight.app"
        xcrun simctl install "$DEVICE_ID" "$APP"
        xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
        sleep 2
        SCREENSHOT="$DERIVED_DATA/Harklight-$DEVICE_ID.png"
        xcrun simctl io "$DEVICE_ID" screenshot --display=primary "$SCREENSHOT"
        DEVELOPER_DIR=$(xcode-select -p)
        SIMULATOR_APP="$DEVELOPER_DIR/Applications/Simulator.app"
        if [ ! -d "$SIMULATOR_APP" ]; then
            SIMULATOR_APP="$(dirname "$DEVELOPER_DIR")/Applications/Simulator.app"
        fi
        if [ -d "$SIMULATOR_APP" ]; then
            open -a "$SIMULATOR_APP" || printf 'Simulator GUI could not be opened; CoreSimulator launch and screenshot are available at %s\n' "$SCREENSHOT"
        else
            printf 'Simulator GUI app is absent; CoreSimulator launch and screenshot are available at %s\n' "$SCREENSHOT"
        fi
        ;;
esac
