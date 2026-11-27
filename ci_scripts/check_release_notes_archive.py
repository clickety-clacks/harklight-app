#!/usr/bin/env python3
"""Validate tracked release notes for an Xcode Cloud archive."""

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Optional


NOTES_PATH = "Resources/HarklightReleaseNotes.json"
APP_PATHS = (
    "Sources/", "Resources/", "AttentionDomain/Sources/", "NativeRelay/Sources/",
    "Configuration/", "project.yml", "Harklight.xcodeproj/project.pbxproj",
)


class CheckFailure(Exception):
    pass


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "git command failed"
        raise CheckFailure(f"cannot evaluate release notes: {detail}")
    return result.stdout


def tree_file_exists(repo: Path, revision: str) -> bool:
    listing = git(repo, "ls-tree", "--full-tree", revision, "--", NOTES_PATH).strip()
    if not listing:
        return False
    try:
        metadata, path = listing.split("\t", 1)
        _, object_type, _ = metadata.split()
    except ValueError as error:
        raise CheckFailure("cannot evaluate release notes: notes file tree entry is malformed") from error
    if path != NOTES_PATH or object_type != "blob":
        raise CheckFailure("cannot evaluate release notes: notes path is not a file")
    return True


def parse_entries(contents: str, source: str) -> list[dict]:
    try:
        document = json.loads(contents)
    except json.JSONDecodeError as error:
        raise CheckFailure(f"{source} release notes do not parse: {error}") from error
    if not isinstance(document, dict) or not isinstance(document.get("entries"), list):
        raise CheckFailure(f"{source} release notes must contain an entries array")

    entries = document["entries"]
    identifiers = set()
    for index, entry in enumerate(entries):
        label = f"{source} release note {index + 1}"
        if not isinstance(entry, dict):
            raise CheckFailure(f"{label} must be an object")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier.strip():
            raise CheckFailure(f"{label} must have a non-empty string ID")
        if identifier in identifiers:
            raise CheckFailure(f"duplicate generated release note ID: {identifier}")
        identifiers.add(identifier)
        if not isinstance(entry.get("marketingVersion"), str) or not entry["marketingVersion"].strip():
            raise CheckFailure(f"{label} must have a marketing version")
        highlights = entry.get("highlights")
        if not isinstance(highlights, list) or not highlights:
            raise CheckFailure(f"{label} must have at least one highlight")
        for highlight in highlights:
            if not isinstance(highlight, dict) or any(
                not isinstance(highlight.get(key), str) or not highlight[key].strip()
                for key in ("id", "symbol", "title", "detail")
            ):
                raise CheckFailure(f"{label} has an invalid highlight")
    return entries


def read_entries(repo: Path, revision: str, source: str) -> list[dict]:
    contents = git(repo, "show", f"{revision}:{NOTES_PATH}")
    return parse_entries(contents, source)


def first_parent(repo: Path, head: str) -> str:
    parents = git(repo, "rev-list", "--parents", "-n", "1", head).split()
    if len(parents) < 2:
        try:
            git(repo, "fetch", "--quiet", "--no-tags", "--deepen=1", "origin", head)
        except CheckFailure as error:
            raise CheckFailure(
                "cannot evaluate release notes: HEAD's first parent is unavailable"
            ) from error
        parents = git(repo, "rev-list", "--parents", "-n", "1", head).split()
    if len(parents) < 2:
        raise CheckFailure("cannot evaluate release notes: HEAD's first parent is unavailable")

    parent = parents[1]
    git(repo, "rev-parse", "--verify", f"{parent}^{{commit}}")
    return parent


def requires_release_note(repo: Path, parent: str, head: str) -> bool:
    changed = git(repo, "diff", "--name-only", "--no-renames", "-z", parent, head, "--",
                  *APP_PATHS).split("\0")
    return any(path and path != NOTES_PATH for path in changed)


def displayed_highlights(entry: dict) -> list[tuple[str, str]]:
    return [(highlight["title"], highlight["detail"]) for highlight in entry["highlights"]]


def omit_carried_pending_entry(repo: Path, head: str) -> None:
    contents = git(repo, "show", f"{head}:{NOTES_PATH}")
    document = json.loads(contents)
    released = [entry for entry in document["entries"] if entry.get("testFlightBuildNumber") is not None]
    if len(released) < len(document["entries"]):
        document["entries"] = released
        (repo / NOTES_PATH).write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                                       encoding="utf-8")
        print("Omitted the carried pending entry from this archive; stamped history is preserved.")


def check(repo: Path, commit: str) -> tuple[Optional[str], bool]:
    head = git(repo, "rev-parse", "--verify", "HEAD^{commit}").strip()
    resolved_commit = git(repo, "rev-parse", "--verify", f"{commit}^{{commit}}").strip()
    if not resolved_commit or resolved_commit != head:
        raise CheckFailure("cannot evaluate release notes: CI commit does not match checkout HEAD")

    if not tree_file_exists(repo, head):
        raise CheckFailure(f"missing release notes file: {NOTES_PATH}")
    current_entries = read_entries(repo, head, "current")
    pending = [entry for entry in current_entries if entry.get("testFlightBuildNumber") is None]
    if len(pending) > 1:
        raise CheckFailure(
            "release notes must contain at most one pending entry; "
            f"found {len(pending)}"
        )

    for entry in current_entries:
        if entry.get("testFlightBuildNumber") is None:
            continue
        build_number = entry.get("testFlightBuildNumber")
        if type(build_number) is not int or build_number <= 0:
            raise CheckFailure(
                f"stamped release note {entry['id']} must have a positive integer TestFlight number"
            )

    parent = first_parent(repo, head)
    if not pending:
        if requires_release_note(repo, parent, head):
            raise CheckFailure("App changes need a new or updated pending in-app What’s New entry")
        return None, False

    pending_id = pending[0]["id"]
    previous_entries = (
        read_entries(repo, parent, "first-parent") if tree_file_exists(repo, parent) else []
    )
    previous_by_id = {entry["id"]: entry for entry in previous_entries}
    previous = previous_by_id.get(pending_id)
    if previous is not None and previous.get("testFlightBuildNumber") is not None:
        raise CheckFailure(f"pending release note {pending_id} was already released in the first parent")

    prior_pending = [
        displayed_highlights(entry) for entry in previous_entries
        if entry.get("testFlightBuildNumber") is None
    ]
    if displayed_highlights(pending[0]) in prior_pending:
        if requires_release_note(repo, parent, head):
            raise CheckFailure(
                f"pending release note {pending_id} has unchanged text; "
                "update in-app What’s New for this App change"
            )
        return None, False
    return pending_id, previous is not None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--prepare-archive", action="store_true",
                        help="Exclude a carried pending entry from an otherwise valid archive.")
    args = parser.parse_args()
    try:
        repo = args.repo.resolve()
        pending_id, was_updated = check(repo, args.commit)
        if args.prepare_archive and pending_id is None:
            omit_carried_pending_entry(repo, args.commit)
    except (CheckFailure, OSError) as error:
        print(f"Release notes archive check failed: {error}", file=sys.stderr)
        return 1
    if pending_id is None:
        print("Release notes archive check passed: no fresh in-app entry needed for this change.")
    else:
        change = "updated" if was_updated else "new"
        print(f"Release notes archive check passed: {change} pending entry {pending_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
