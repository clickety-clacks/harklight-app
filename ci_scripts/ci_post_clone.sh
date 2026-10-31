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
