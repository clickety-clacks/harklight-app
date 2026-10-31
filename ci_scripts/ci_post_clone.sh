#!/bin/sh
set -eu

# A release build must account for every app change since this check was added.
# The starting commit is a source revision, not an App Store build number.
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

repo=${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud did not provide the source path}
commit=${CI_COMMIT:?Xcode Cloud did not provide the source revision}
base=ccaabc211da453c21c44fc8ca6e3ff19851332e2

if ! git -C "$repo" merge-base --is-ancestor "$base" "$commit"; then
    printf '%s\n' 'Release notes could not be checked against the source history.' >&2
    exit 1
fi

revisions=$(git -C "$repo" rev-list --first-parent --reverse "$base..$commit")
for revision in $revisions; do
    parent=$(git -C "$repo" rev-parse "$revision^1")
    changed=$(git -C "$repo" diff --name-only "$parent" "$revision" -- \
        Sources AttentionDomain/Sources NativeRelay/Sources Resources \
        Design/tokens.json Configuration/HarklightInfo.plist \
        Signing/ReceiverDevelopment.entitlements project.yml \
        Harklight.xcodeproj/project.pbxproj AttentionDomain/Package.swift \
        NativeRelay/Package.swift)
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
        printf 'Release notes could not be checked for %s.\n' "$revision" >&2
        exit 1
    fi

    # A source-only maintenance change may say why it has no user-facing note.
    # For a merge, the source branch's last commit carries that declaration.
    message_commit=$revision
    set -- $(git -C "$repo" rev-list --parents -n 1 "$revision")
    if [ "$#" -ge 3 ]; then
        message_commit=$3
    fi
    if git -C "$repo" log -1 --format=%B "$message_commit" |
        grep -Eq '^Release-Notes: none - .+'; then
        continue
    fi

    printf 'App source changed in %s without a release note or a reason it needs none.\n' "$revision" >&2
    printf '%s\n' 'Update Sources/ReleaseNotes.swift or add "Release-Notes: none - <reason>" to the source commit.' >&2
    exit 1
done
