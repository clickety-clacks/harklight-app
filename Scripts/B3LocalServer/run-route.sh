#!/bin/bash
set -euo pipefail
umask 077

work=${1:?fixture scratch}
xctestrun=${2:?prebuilt XCTest metadata}
route=${3:?bridge, paste, or native}
dashboard=${4:?isolated dashboard origin}
[[ $route =~ ^(bridge|paste|native)$ ]]
scripts=$(cd "$(dirname "$0")" && pwd -P)
route_dir="$work/route-$route"
mkdir "$route_dir"
device=''
test_pid=''
phase=''
signals=''

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ $status != 0 ]]; then
        printf 'B3 route=%s failed during %s (exit %s)\n' "$route" "$phase" "$status" >&2
        if [[ -f "$route_dir/xctest.log" ]]; then
            grep -E 'Test Case.*B3EnrollmentProof.*(started|passed|failed)|\*\* TEST (SUCCEEDED|FAILED) \*\*' "$route_dir/xctest.log" || true
        fi
    fi
    if [[ -n $test_pid ]]; then kill "$test_pid" 2>/dev/null || true; wait "$test_pid" 2>/dev/null || true; fi
    if [[ -n $signals ]]; then
        for signal in bridge-resolved invite-confirmed request-pending owner-approved connected enrolled cold-restored offline-removal-kept-account confirmed-removal-kept-unsent-text; do
            if [[ -f "$signals/$signal" ]]; then
                printf 'B3 observed route=%s %s\n' "$route" "$signal"
            fi
        done
    fi
    if [[ -n $device ]]; then
        data=$(xcrun simctl get_app_container "$device" co.clicketyclacks.Harklight data 2>/dev/null || true)
        diagnostic="$data/Library/Application Support/Harklight/native-client-diagnostics-v1.json"
        if [[ -n $data && -f $diagnostic ]]; then
            python3 "$scripts/enrollment-diagnostics.py" "$diagnostic" || true
        fi
        observed="$data/Library/Application Support/b3-invitation-handoff.json"
        if [[ -n $data && -f $observed && -f "$route_dir/sent-fragment.json" ]]; then
            python3 "$scripts/compare-invitation-fragments.py" compare "$route_dir/sent-fragment.json" "$observed" || true
        fi
        rejection="$data/Library/Application Support/b3-invitation-reject-field.txt"
        if [[ -n $data && -f $rejection ]]; then
            field=$(cat "$rejection")
            if [[ $field =~ ^[a-z0-9_]{1,42}$ ]]; then
                printf 'B3 invitation parser rejected field %s\n' "$field"
            fi
        fi
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

phase='boot test-owned simulator'
candidate=$(xcrun simctl create B3LocalServer-$route 'iPhone 17 Pro' 'iOS 27.0')
[[ $candidate =~ ^[A-Fa-f0-9-]{36}$ ]]
device=$candidate
xcrun xcodebuild -project Harklight.xcodeproj -scheme Harklight -showdestinations > "$route_dir/destinations.log"
grep -Fq "$device" "$route_dir/destinations.log"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
if [[ $route == bridge ]]; then
    xcrun simctl keychain "$device" add-root-cert "$work/state/tls/ca.pem"
fi

phase='launch UI test and wait for readiness'
xcrun xcodebuild -xctestrun "$xctestrun" -destination "id=$device" -jobs 2 \
    -parallel-testing-enabled NO -only-testing:HarklightUITests/B3EnrollmentProof/testInviteRelaunchAndSignOutOnOneDevice \
    test-without-building > "$route_dir/xctest.log" 2>&1 &
test_pid=$!

runner=com.example.attentionclient.duo-prototype.uitests.xctrunner
for ((i=0; i<150; i++)); do
    kill -0 "$test_pid" 2>/dev/null || break
    data=$(xcrun simctl get_app_container "$device" "$runner" data 2>/dev/null || true)
    if [[ -n $data && -f "$data/Documents/ready" ]]; then
        signals="$data/Documents"
        break
    fi
    sleep 1
done
[[ -n $signals ]]

phase='deliver fresh owner invitation'
bash "$scripts/fixture.sh" invite "$work" "$route_dir/invitation.json" > "$route_dir/invite.log" 2>&1
python3 "$scripts/compare-invitation-fragments.py" original "$route_dir/invitation.json" "$route_dir/sent-fragment.json"
python3 "$scripts/deliver-invitation.py" "$route_dir/invitation.json" "$signals" "$device" "$route" "$dashboard"
rm "$route_dir/invitation.json"

phase='approve displayed device code'
code=''
for ((i=0; i<45; i++)); do
    if code=$(cat "$signals/approval" 2>/dev/null) && [[ -n $code ]]; then
        break
    fi
    kill -0 "$test_pid" 2>/dev/null || break
    sleep 1
done
if [[ -z $code ]]; then
    printf '%s\n' 'The UI test did not provide an approval code.'
    exit 65
fi
bash "$scripts/fixture.sh" approve "$work" "$code" > "$route_dir/approval.log" 2>&1
unset code
rm -f "$signals/approval"
touch "$signals/approved"
printf 'B3 owner CLI approved route=%s\n' "$route"

phase='verify cold relaunch and offline sign-out'
wait "$test_pid"
test_pid=''
for signal in enrolled cold-restored offline-removal-kept-account confirmed-removal-kept-unsent-text; do
    [[ -f "$signals/$signal" ]]
    printf 'B3 PASS route=%s %s\n' "$route" "$signal"
done
