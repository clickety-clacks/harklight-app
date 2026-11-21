#!/bin/bash
set -euo pipefail
umask 077

scratch=${1:?runner scratch directory}
scripts=$(cd "$(dirname "$0")" && pwd -P)
fixture="$scripts/../B3LocalServer"
repo=$(git -C "$scripts" rev-parse --show-toplevel)
old=aaadce98265f42a85b0dd00446bdd7e24f46095e
new=357cce64f02c55ae28f2b73a275917ba3c13b95b
bundle=co.clicketyclacks.Harklight
runner=com.example.attentionclient.duo-prototype.uitests.xctrunner
work=$(mktemp -d "$scratch/harklight-upgrade.XXXXXX")
device=''
server_pid=''
test_pid=''
phase='prepare'

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [[ $status != 0 ]]; then printf 'Upgrade stopped during %s (exit %s)\n' "$phase" "$status" >&2; fi
    if [[ -n $test_pid ]]; then kill "$test_pid" 2>/dev/null || true; wait "$test_pid" 2>/dev/null || true; fi
    if [[ -n $device ]]; then
        xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
        xcrun simctl delete "$device" >/dev/null 2>&1 || status=1
    fi
    if [[ -n $server_pid ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    for revision in 0.1 0.2; do
        if [[ -f "$work/$revision/.git" ]]; then git -C "$repo" worktree remove --force "$work/$revision"; fi
    done
    rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

build() {
    local version=$1 revision=$2 app="$work/$1" build="$work/build-$1"
    git -C "$repo" worktree add --detach "$app" "$revision"
    [[ $(git -C "$app" rev-parse HEAD) == "$revision" ]]
    cp "$scripts/InstallOverUIProof.swift" "$app/UITests/B4InstallOverUIProof.swift"
    cp "$scripts/IdentityEvidence.swift" "$app/Tests/B4UpgradeIdentityEvidence.swift"
    (
        cd "$app"
        Scripts/prepare-test-tls.sh
        xcodegen generate
        xcrun xcodebuild -quiet -project Harklight.xcodeproj -scheme Harklight \
            -destination 'generic/platform=iOS Simulator' -derivedDataPath "$build" \
            -jobs 2 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing
    )
    local product="$build/Build/Products/Debug-iphonesimulator/Harklight.app"
    [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$product/Info.plist") == "$bundle" ]]
    [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$product/Info.plist") == "$version.0" ]]
    printf '%s\n' "$product" > "$work/product-$version"
    codesign -d --entitlements :- "$product" > "$work/entitlements-$version.plist" 2>/dev/null
    local run_file
    run_file=$(find "$build/Build/Products" -maxdepth 1 -name '*.xctestrun' -print)
    [[ -n $run_file && $run_file != *$'\n'* ]]
    printf '%s\n' "$run_file" > "$work/test-$version"
}

run_case() {
    local version=$1 selector=$2 log=$3
    xcrun xcodebuild -xctestrun "$(cat "$work/test-$version")" -destination "id=$device" \
        -jobs 2 -parallel-testing-enabled NO -only-testing:"$selector" \
        -collect-test-diagnostics never test-without-building > "$log" 2>&1
}

report_case() {
    local log=$1
    # XCTest can echo the invitation and approval UI. Publish only the case state and source locations.
    grep -E 'Test Case.*(B4InstallOverUIProof|B4UpgradeIdentityEvidence).*(started|passed|failed)|\*\* TEST (SUCCEEDED|FAILED) \*\*' "$log" || true
    grep -Eo '(B4InstallOverUIProof|B4UpgradeIdentityEvidence)\.swift:[0-9]+' "$log" | sort -u || true
}

export PATH="$(brew --prefix openssl@3)/bin:$PATH"
phase='compile and seed private Server'
bash "$fixture/build-server.sh" "$work/server" "$work/release"
bash "$fixture/fixture.sh" bootstrap "$work"
bash "$fixture/fixture.sh" start "$work" > "$work/server.log" 2>&1 &
server_pid=$!
bash "$fixture/fixture.sh" seed "$work" > "$work/seed.log" 2>&1
echo 'Private Server 1dc7ecb seeded through its real v2 API.'

phase='compile exact app revisions and compare signing entitlements'
build 0.1 "$old"
build 0.2 "$new"
python3 - "$work" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
keys = ("application-identifier", "com.apple.application-identifier",
        "com.apple.developer.team-identifier", "keychain-access-groups")
def access(version):
    raw = (root / f"entitlements-{version}.plist").read_bytes()
    entitlements = plistlib.loads(raw) if raw else {}
    return {key: entitlements.get(key) for key in keys}
before, after = access("0.1"), access("0.2")
if before != after:
    sys.exit("The simulator products have different identity or Keychain access entitlements.")
print("Simulator signing identity and Keychain access entitlements match.")
PY

phase='boot one owned device and install 0.1'
device=$(xcrun simctl create B4InstallOver 'iPhone 17 Pro' 'iOS 27.0')
[[ $device =~ ^[A-Fa-f0-9-]{36}$ ]]
xcrun xcodebuild -project "$work/0.1/Harklight.xcodeproj" -scheme Harklight -showdestinations > "$work/destinations.log"
grep -Fq "$device" "$work/destinations.log"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$(cat "$work/product-0.1")"

phase='enroll 0.1 with v1 invite and persist approval'
run_case 0.1 HarklightUITests/B4InstallOverUIProof/testEnrollBeforeUpdate "$work/enroll.log" &
test_pid=$!
signals=''
for ((i=0; i<150; i++)); do
    kill -0 "$test_pid" 2>/dev/null || break
    data=$(xcrun simctl get_app_container "$device" "$runner" data 2>/dev/null || true)
    if [[ -n $data && -f "$data/Documents/ready" ]]; then signals="$data/Documents"; break; fi
    sleep 1
done
if [[ -z $signals ]]; then report_case "$work/enroll.log"; exit 65; fi
bash "$fixture/fixture.sh" invite "$work" "$work/invitation.json" > "$work/invite.log" 2>&1
python3 "$fixture/deliver-invitation.py" "$work/invitation.json" "$signals" "$device" native https://localhost:18447
rm "$work/invitation.json"
code=''
for ((i=0; i<90; i++)); do
    if code=$(cat "$signals/approval" 2>/dev/null) && [[ -n $code ]]; then break; fi
    kill -0 "$test_pid" 2>/dev/null || break
    sleep 1
done
if [[ -z $code ]]; then report_case "$work/enroll.log"; exit 65; fi
bash "$fixture/fixture.sh" approve "$work" "$code" > "$work/approval.log" 2>&1
unset code
rm -f "$signals/approval"
touch "$signals/approved"
if ! wait "$test_pid"; then report_case "$work/enroll.log"; exit 1; fi
test_pid=''
[[ -f "$signals/durable-approval" ]]
report_case "$work/enroll.log"

phase='read durable 0.1 identity'
run_case 0.1 HarklightTests/B4UpgradeIdentityEvidence/testBeforeUpdate "$work/before.log" || {
    report_case "$work/before.log"; exit 1;
}
report_case "$work/before.log"
xcrun simctl terminate "$device" "$bundle" >/dev/null 2>&1 || true
data=$(xcrun simctl get_app_container "$device" "$bundle" data)
touch "$data/b4-install-over-marker"

phase='install 0.2 over 0.1 and preserve the sandbox'
xcrun simctl install "$device" "$(cat "$work/product-0.2")"
app_path=$(xcrun simctl get_app_container "$device" "$bundle" app)
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Info.plist") == 0.2.0 ]]
assert_sandbox_retained() {
    local current
    current=$(xcrun simctl get_app_container "$device" "$bundle" data)
    [[ -f "$current/b4-install-over-marker" ]]
}
assert_sandbox_retained
echo 'Installed 0.2.0 over 0.1.0 and retained the application data sandbox.'

phase='verify authenticated /me and key continuity'
run_case 0.2 HarklightTests/B4UpgradeIdentityEvidence/testAfterUpdate "$work/after.log" || {
    report_case "$work/after.log"; exit 1;
}
report_case "$work/after.log"
assert_sandbox_retained
python3 - "$work" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def identity(phase):
    log = (root / f"{phase}.log").read_text(errors="replace")
    match = re.search(rf"B4-UPGRADE phase={phase} certificate=([0-9a-f]{{64}}) "
                      r"public_key=([0-9a-f]{64}) device=([0-9a-f]{64})", log)
    if match is None:
        sys.exit(f"No complete {phase} identity evidence was emitted.")
    return match.groups()
before, after = identity("before"), identity("after")
for field, old_hash, new_hash in zip(("certificate", "public key", "device ID"), before, after):
    print(f"{field} hash: {'same' if old_hash == new_hash else 'CHANGED'}")
    print(f"  before {old_hash}  after {new_hash}")
if before != after:
    sys.exit("The update changed the saved device identity.")
PY

phase='verify seeded inbox and cold relaunch'
run_case 0.2 HarklightUITests/B4InstallOverUIProof/testRestoredSeededInboxAfterUpdateAndColdRelaunch "$work/restore.log" || {
    report_case "$work/restore.log"; exit 1;
}
report_case "$work/restore.log"
assert_sandbox_retained
echo 'B4 PASS: in-place update retained certificate, public key, authenticated device ID, and seeded inbox across cold relaunch.'
