#!/bin/bash
set -euo pipefail
umask 077

scratch=${1:?runner scratch directory}
scripts=$(cd "$(dirname "$0")" && pwd -P)
app=$(git -C "$scripts" rev-parse --show-toplevel)
work=$(mktemp -d "$scratch/harklight-b3.XXXXXX")
device=''
server_pid=''
test_pid=''
phase='prepare'
signals=''

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ $status != 0 ]]; then
        printf 'B3 failed during %s (exit %s)\n' "$phase" "$status" >&2
        if [[ $phase == 'seed real v2 inbox' && -f "$work/seed.log" ]]; then
            grep -E '^curl: \([0-9]+\) (The requested URL returned error: [0-9]+|Failure when receiving data from the peer|Recv failure: Connection reset by peer)$' "$work/seed.log" || true
        fi
        if [[ -f "$work/xctest.log" ]]; then
            grep -E 'Test Case.*B3EnrollmentProof.*(started|passed|failed)|\*\* TEST (SUCCEEDED|FAILED) \*\*' "$work/xctest.log" || true
        fi
    fi
    if [[ -n $test_pid ]]; then kill "$test_pid" 2>/dev/null || true; wait "$test_pid" 2>/dev/null || true; fi
    if [[ -n $signals ]]; then
        for signal in native-link-confirmed pasted-invite enrolled cold-restored offline-removal-kept-account confirmed-removal-kept-unsent-text; do
            if [[ -f "$signals/$signal" ]]; then
                printf 'B3 observed %s\n' "$signal"
            fi
        done
    fi
    if [[ -n $device ]]; then
        data=$(xcrun simctl get_app_container "$device" co.clicketyclacks.Harklight data 2>/dev/null || true)
        diagnostic="$data/Library/Application Support/Harklight/native-client-diagnostics-v1.json"
        if [[ -n $data && -f $diagnostic ]]; then
            python3 "$scripts/enrollment-diagnostics.py" "$diagnostic" || true
        fi
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || status=1
    fi
    if [[ -n $server_pid ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export PATH="$(brew --prefix openssl@3)/bin:$PATH"
printf 'App %s\n' "$(git -C "$app" rev-parse HEAD)"
elixir --version

phase='compile Server from public source'
bash "$scripts/build-server.sh" "$work/server" "$work/release"
phase='bootstrap loopback fixture'
bash "$scripts/fixture.sh" bootstrap "$work"
bash "$scripts/fixture.sh" start "$work" > "$work/server.log" 2>&1 &
server_pid=$!
phase='seed real v2 inbox'
bash "$scripts/fixture.sh" seed "$work" > "$work/seed.log" 2>&1
printf '%s\n' 'Loopback fixture seeded through authenticated v2 API.'

phase='build app and XCUITest'
mkdir "$work/app"
git -C "$app" archive HEAD | tar -xf - -C "$work/app"
python3 "$scripts/stage-proof.py" "$work/app" "$scripts/B3EnrollmentProof.swift"
cd "$work/app"
./Scripts/prepare-test-tls.sh
xcodegen generate
xcrun xcodebuild -quiet -project Harklight.xcodeproj -scheme Harklight \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/DerivedData" \
    -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
xctestrun=$(find "$work/DerivedData/Build/Products" -maxdepth 1 -name '*.xctestrun' -print)
[[ -n $xctestrun && $xctestrun != *$'\n'* ]]

phase='boot test-owned simulator'
candidate=$(xcrun simctl create B3LocalServer 'iPhone 17 Pro' 'iOS 27.0')
[[ $candidate =~ ^[A-Fa-f0-9-]{36}$ ]]
device=$candidate
xcrun xcodebuild -project Harklight.xcodeproj -scheme Harklight -showdestinations > "$work/destinations.log"
grep -Fq "$device" "$work/destinations.log"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b

phase='launch UI test and wait for readiness'
xcrun xcodebuild -xctestrun "$xctestrun" -destination "id=$device" -jobs 2 \
    -parallel-testing-enabled NO -only-testing:HarklightUITests/B3EnrollmentProof/testInviteRelaunchAndSignOutOnOneDevice \
    test-without-building > "$work/xctest.log" 2>&1 &
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

phase='open real owner invitation'
bash "$scripts/fixture.sh" invite "$work" > "$work/invite.log" 2>&1
invite=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["join_url"])' "$work/invitation.json")
printf '%s' "$invite" | xcrun simctl pbcopy "$device" >/dev/null 2>&1
xcrun simctl openurl "$device" "$invite" >/dev/null 2>&1
unset invite
rm "$work/invitation.json"

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
bash "$scripts/fixture.sh" approve "$work" "$code" > "$work/approval.log" 2>&1
unset code
rm -f "$signals/approval"
touch "$signals/approved"

phase='verify cold relaunch and offline sign-out'
wait "$test_pid"
test_pid=''
for signal in enrolled cold-restored offline-removal-kept-account confirmed-removal-kept-unsent-text; do
    [[ -f "$signals/$signal" ]]
    printf 'B3 PASS %s\n' "$signal"
done
