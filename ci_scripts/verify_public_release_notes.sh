#!/bin/sh
set -eu

fail() {
    printf 'Release notes gate: %s\n' "$1" >&2
    exit 1
}

case "${CI_XCODEBUILD_ACTION:-}" in
    archive) ;;
    *) exit 0 ;;
esac
if [ -n "${CI_PULL_REQUEST_NUMBER:-}" ]; then
    exit 0
fi

repo=${CI_PRIMARY_REPOSITORY_PATH:-}
commit=${CI_COMMIT:-}
base=803fe1547dfd1f3cacc314d4e510b99050116f53

if [ -z "$repo" ] || [ -z "$commit" ]; then
    fail 'The source path or revision is unavailable; the archive cannot be attributed.'
fi

provenance_file="$repo/Resources/HarklightBuildProvenance.plist"
resolved_commit=$(git -C "$repo" rev-parse --verify "$commit^{commit}" 2>/dev/null) ||
    fail 'The declared source revision cannot be resolved.'
checkout_commit=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null) ||
    fail 'The checked-out source revision cannot be resolved.'
if [ "$resolved_commit" != "$checkout_commit" ]; then
    fail 'The declared source revision does not match the checked-out revision.'
fi
source_tree=$(git -C "$repo" rev-parse --verify "$resolved_commit^{tree}" 2>/dev/null) ||
    fail 'The source tree cannot be resolved.'
case "$resolved_commit:$source_tree" in
    *[!0123456789abcdef:]*|'') fail 'The source commit or tree identifier is malformed.' ;;
esac
if [ "${#resolved_commit}" -ne 40 ] || [ "${#source_tree}" -ne 40 ]; then
    fail 'The source commit or tree identifier is incomplete.'
fi
if [ ! -f "$provenance_file" ]; then
    fail 'The app source provenance resource is missing.'
fi

build_number=${CI_BUILD_NUMBER:-}
case "$build_number" in
    ''|*[!0123456789]*) fail 'The public archive has no numeric Xcode Cloud build number.' ;;
esac
if [ "$build_number" -le 0 ]; then
    fail 'The public archive build number must be greater than zero.'
fi

if ! cat > "$provenance_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>HarklightSourceCommit</key><string>$resolved_commit</string>
    <key>HarklightSourceTree</key><string>$source_tree</string>
</dict>
</plist>
PLIST
then
    fail 'Source provenance could not be written.'
fi

if ! git -C "$repo" merge-base --is-ancestor "$base" "$commit"; then
    fail 'Release-note source history is unavailable from the approved baseline.'
fi

revisions=$(git -C "$repo" rev-list --first-parent --reverse "$base..$commit") ||
    fail 'Source revisions could not be read.'
for revision in $revisions; do
    parent=$(git -C "$repo" rev-parse "$revision^1") ||
        fail 'A source parent could not be read.'
    changed=$(git -C "$repo" diff --name-only "$parent" "$revision" -- \
        Sources AttentionDomain/Sources NativeRelay/Sources Resources \
        Design/tokens.json Configuration/HarklightInfo.plist \
        Signing/ReceiverDevelopment.entitlements project.yml \
        Harklight.xcodeproj/project.pbxproj AttentionDomain/Package.swift \
        NativeRelay/Package.swift) || fail 'Source changes could not be read.'
    if [ -z "$changed" ]; then
        continue
    fi

    if git -C "$repo" diff --quiet "$parent" "$revision" -- Sources/ReleaseNotes.swift; then
        :
    else
        diff_status=$?
        if [ "$diff_status" -eq 1 ]; then
            continue
        fi
        fail "Release notes for source revision $revision could not be checked."
    fi

    message_commit=$revision
    parents=$(git -C "$repo" rev-list --parents -n 1 "$revision") ||
        fail 'Source revision parents could not be read.'
    set -- $parents
    if [ "$#" -ge 3 ]; then
        message_commit=$3
    fi
    message=$(git -C "$repo" log -1 --format=%B "$message_commit") ||
        fail 'The source commit message could not be read.'
    if printf '%s\n' "$message" | grep -Eq '^Release-Notes: none - .+'; then
        continue
    fi

    fail "App source changed in $revision without a release note or a Release-Notes: none - <reason> declaration."
done

exit 0
