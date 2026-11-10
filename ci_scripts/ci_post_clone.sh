#!/bin/sh
set -u

# Report source changes that need release-note attention without stopping a build.
# The starting commit is a source revision, not an App Store build number.
warn() {
    printf 'Release notes warning: %s\n' "$1" >&2
}
case "${CI_XCODE_CLOUD:-}" in
    TRUE|true|1) ;;
    *) exit 0 ;;
esac
case "${CI_XCODEBUILD_ACTION:-}" in
    archive|build) ;;
    *) exit 0 ;;
esac
if [ -n "${CI_PULL_REQUEST_NUMBER:-}" ]; then
    exit 0
fi

repo=${CI_PRIMARY_REPOSITORY_PATH:-}
commit=${CI_COMMIT:-}
base=ccaabc211da453c21c44fc8ca6e3ff19851332e2

if [ -z "$repo" ] || [ -z "$commit" ]; then
    warn 'The source path or revision is unavailable; continuing the build.'
    exit 0
fi

# Embed source provenance only when the build's declared commit is exactly the
# checked-out commit. Invalid or unavailable CI metadata remains explicitly
# unavailable in the app's diagnostics export.
provenance_file="$repo/Resources/HarklightBuildProvenance.plist"
resolved_commit=$(git -C "$repo" rev-parse --verify "$commit^{commit}" 2>/dev/null || true)
checkout_commit=$(git -C "$repo" rev-parse --verify HEAD 2>/dev/null || true)
if [ -n "$resolved_commit" ] && [ "$resolved_commit" = "$checkout_commit" ]; then
    source_tree=$(git -C "$repo" rev-parse --verify "$resolved_commit^{tree}" 2>/dev/null || true)
    case "$resolved_commit:$source_tree" in
        *[!0123456789abcdef:]*|'') resolved_commit=; source_tree= ;;
    esac
    if [ "${#resolved_commit}" -ne 40 ] || [ "${#source_tree}" -ne 40 ]; then
        resolved_commit=
        source_tree=
    fi
else
    resolved_commit=
    source_tree=
fi
if [ -n "$resolved_commit" ] && [ -f "$provenance_file" ]; then
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
        warn 'Source provenance could not be written; continuing the build with unavailable provenance.'
    fi
else
    warn 'The checked-out source revision could not be verified; continuing the build with unavailable provenance.'
fi

if ! git -C "$repo" merge-base --is-ancestor "$base" "$commit"; then
    warn 'Source history is unavailable; continuing the build.'
    exit 0
fi

if ! revisions=$(git -C "$repo" rev-list --first-parent --reverse "$base..$commit"); then
    warn 'Source revisions could not be read; continuing the build.'
    exit 0
fi
for revision in $revisions; do
    if ! parent=$(git -C "$repo" rev-parse "$revision^1"); then
        warn 'A source parent could not be read; continuing the build.'
        exit 0
    fi
    if ! changed=$(git -C "$repo" diff --name-only "$parent" "$revision" -- \
        Sources AttentionDomain/Sources NativeRelay/Sources Resources \
        Design/tokens.json Configuration/HarklightInfo.plist \
        Signing/ReceiverDevelopment.entitlements project.yml \
        Harklight.xcodeproj/project.pbxproj AttentionDomain/Package.swift \
        NativeRelay/Package.swift); then
        warn 'Source changes could not be read; continuing the build.'
        exit 0
    fi
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
        warn "Changes in $revision could not be checked; continuing the build."
        exit 0
    fi

    # A source-only maintenance change may say why it has no user-facing note.
    # For a merge, the source branch's last commit carries that declaration.
    message_commit=$revision
    if ! parents=$(git -C "$repo" rev-list --parents -n 1 "$revision"); then
        warn 'Revision parents could not be read; continuing the build.'
        exit 0
    fi
    set -- $parents
    if [ "$#" -ge 3 ]; then
        message_commit=$3
    fi
    if ! message=$(git -C "$repo" log -1 --format=%B "$message_commit"); then
        warn 'The source message could not be read; continuing the build.'
        exit 0
    fi
    if printf '%s\n' "$message" | grep -Eq '^Release-Notes: none - .+'; then
        continue
    fi

    warn "App source changed in $revision without a release note or a reason it needs none."
done
exit 0
