#!/bin/bash
set -euo pipefail
umask 077

scratch=${1:?runner scratch directory}
scripts=$(cd "$(dirname "$0")" && pwd -P)
app=$(git -C "$scripts" rev-parse --show-toplevel)
work=$(mktemp -d "$scratch/harklight-b3.XXXXXX")
server_pid=''
phase='prepare'

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ $status != 0 ]]; then
        printf 'B3 job stopped during %s (exit %s)\n' "$phase" "$status" >&2
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
python3 "$scripts/instrument-invitation.py" "$work/app"
cd "$work/app"
./Scripts/prepare-test-tls.sh
xcodegen generate
xcrun xcodebuild -quiet -project Harklight.xcodeproj -scheme Harklight \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$work/DerivedData" \
    -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
xctestrun=$(find "$work/DerivedData/Build/Products" -maxdepth 1 -name '*.xctestrun' -print)
[[ -n $xctestrun && $xctestrun != *$'\n'* ]]

phase='prove invitation routes'
passes=0
for route in bridge paste native; do
    status=0
    /bin/bash "$scripts/run-route.sh" "$work" "$xctestrun" "$route" https://localhost:18447 || status=$?
    printf 'B3 outcome route=%s exit=%s\n' "$route" "$status"
    if [[ $status == 0 ]]; then passes=$((passes + 1)); fi
done
[[ $passes -gt 0 ]]
