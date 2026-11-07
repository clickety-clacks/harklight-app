#!/bin/sh
set -u

# Validate tracked release notes for non-pull-request Xcode Cloud archives.
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

if [ -z "$repo" ] || [ -z "$commit" ]; then
    warn 'The source path or revision is unavailable.'
    if [ "${CI_XCODEBUILD_ACTION:-}" = archive ]; then
        exit 1
    fi
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

if [ "${CI_XCODEBUILD_ACTION:-}" != archive ]; then
    exit 0
fi

exec python3 "$repo/ci_scripts/check_release_notes_archive.py" --repo "$repo" --commit "$commit"
