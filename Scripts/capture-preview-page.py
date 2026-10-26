#!/usr/bin/env python3
"""Capture a portrait Harklight preview page from available simulator UI screenshots."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TEST_ID = "HarklightUITests/SampleWorkspaceUITests/testPreviewPageCapturesInboxAndDetail"
TEST_LABELS = {
    "inbox": ("Inbox", "preview-portrait-inbox"),
    "detail": ("Message detail", "preview-portrait-detail"),
}
APPEARANCES = ("light", "dark")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class CaptureError(RuntimeError):
    pass


def add_warning(warnings: list[str], message: str) -> None:
    if message not in warnings:
        warnings.append(message)
        print(f"Warning: {message}", file=sys.stderr)


def attempt(command: list[str], *, env: dict[str, str] | None = None) -> dict:
    try:
        result = subprocess.run(
            command, cwd=ROOT, env=env, check=False, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
    except OSError as error:
        return {"returnCode": None, "output": "", "error": str(error)}
    return {
        "returnCode": result.returncode,
        "output": result.stdout or "",
        "error": None,
    }


def run(command: list[str], *, capture_output: bool = False,
        env: dict[str, str] | None = None) -> str:
    result = attempt(command, env=env)
    if result["error"] or result["returnCode"] != 0:
        detail = result["output"] if capture_output else ""
        error = result["error"] or f"Command failed ({result['returnCode']})"
        raise CaptureError(
            f"{error}: {' '.join(command)}"
            + (f"\n{detail[-12000:]}" if detail else "")
        )
    return result["output"].strip() if capture_output else ""


def parse_timestamp(value: str) -> dt.datetime:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise CaptureError("--pushed-at must be an ISO 8601 timestamp with a timezone.") from error
    if parsed.tzinfo is None:
        raise CaptureError("--pushed-at must include a timezone, for example 2026-10-23T15:12:00Z.")
    return parsed.astimezone(dt.timezone.utc)


def timestamp_text(value: dt.datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def find_simulator(device_id: str) -> str | None:
    raw = run(["xcrun", "simctl", "list", "devices", "--json"], capture_output=True)
    devices = json.loads(raw).get("devices", {})
    for runtime_devices in devices.values():
        for device in runtime_devices:
            if device.get("udid") == device_id:
                name = device.get("name")
                if device.get("state") != "Booted":
                    raise CaptureError(f"Simulator {name or device_id!r} is not booted.")
                return name if isinstance(name, str) and name.strip() else None
    raise CaptureError("HARKLIGHT_SIMULATOR_ID does not name an available simulator.")


def result_bundles() -> set[Path]:
    directory = ROOT / "DerivedData" / "Logs" / "Test"
    return {path.resolve() for path in directory.glob("*.xcresult")}


def locate_result_bundle(before: set[Path], output: str,
                         warnings: list[str]) -> Path | None:
    try:
        new_bundles = [
            path for path in result_bundles() - before
            if path.exists()
        ]
        new_bundles.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    except OSError as error:
        new_bundles = []
        add_warning(warnings, f"Could not inspect Xcode result bundles: {error}")

    if new_bundles:
        return new_bundles[0]

    for match in reversed(re.findall(r"(/[^\r\n]*?\.xcresult)", output)):
        candidate = Path(match.rstrip(" .,:;")).resolve()
        if candidate.exists():
            return candidate
    return None


def run_capture_test(device_id: str, appearance: str, export_dir: Path,
                     warnings: list[str]) -> tuple[dict, list[dict]]:
    try:
        before = result_bundles()
    except OSError as error:
        before = set()
        add_warning(warnings, f"Could not snapshot existing Xcode result bundles: {error}")

    env = os.environ.copy()
    env["HARKLIGHT_SIMULATOR_ID"] = device_id
    env["HARKLIGHT_ONLY_TESTING"] = TEST_ID
    print(f"Capturing the Inbox and selected detail in {appearance} appearance…", flush=True)
    wrapper = attempt([str(ROOT / "Scripts" / "verify.sh"), "test"], env=env)
    output = wrapper["output"]
    bundle = locate_result_bundle(before, output, warnings)

    test_record = {
        "appearance": appearance,
        "wrapperExitCode": wrapper["returnCode"],
        "wrapperError": wrapper["error"],
        "result": None,
        "passedTests": None,
        "failedTests": None,
        "testPassed": None,
        "resultBundle": str(bundle) if bundle else None,
        "attachmentExportExitCode": None,
        "manifestAvailable": False,
    }
    if wrapper["error"]:
        add_warning(warnings, f"{appearance}: could not start the test wrapper: {wrapper['error']}")
    elif wrapper["returnCode"] != 0:
        add_warning(
            warnings,
            f"{appearance}: the targeted UI test wrapper exited {wrapper['returnCode']}; "
            "available attachments will still be shown as unverified.",
        )

    if bundle is None:
        add_warning(warnings, f"{appearance}: no new Xcode result bundle was found.")
        return test_record, []

    summary_result = attempt([
        "xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle),
    ])
    summary = None
    if summary_result["error"]:
        add_warning(warnings, f"{appearance}: could not read the Xcode result summary: {summary_result['error']}")
    elif summary_result["returnCode"] != 0:
        add_warning(warnings, f"{appearance}: Xcode could not read the test result summary.")
    else:
        try:
            summary = json.loads(summary_result["output"])
        except json.JSONDecodeError as error:
            add_warning(warnings, f"{appearance}: the Xcode result summary was invalid JSON: {error}")

    if isinstance(summary, dict):
        test_record.update({
            "result": summary.get("result"),
            "passedTests": summary.get("passedTests"),
            "failedTests": summary.get("failedTests"),
        })
        if wrapper["returnCode"] == 0 and summary.get("result") == "Passed" and summary.get("failedTests") == 0:
            test_record["testPassed"] = True
        elif wrapper["returnCode"] not in (None, 0) or summary.get("result") != "Passed" or summary.get("failedTests") != 0:
            test_record["testPassed"] = False
            add_warning(warnings, f"{appearance}: the targeted UI test did not pass.")
    elif wrapper["returnCode"] == 0:
        add_warning(warnings, f"{appearance}: test outcome could not be verified.")

    try:
        export_dir.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        add_warning(warnings, f"{appearance}: could not create the attachment export folder: {error}")
        return test_record, []

    export_result = attempt([
        "xcrun", "xcresulttool", "export", "attachments",
        "--path", str(bundle), "--output-path", str(export_dir),
    ])
    test_record["attachmentExportExitCode"] = export_result["returnCode"]
    if export_result["error"]:
        add_warning(warnings, f"{appearance}: attachment export could not start: {export_result['error']}")
    elif export_result["returnCode"] != 0:
        add_warning(warnings, f"{appearance}: attachment export exited {export_result['returnCode']}.")

    manifest_path = export_dir / "manifest.json"
    if not manifest_path.is_file():
        add_warning(warnings, f"{appearance}: XCTest attachment manifest is unavailable.")
        return test_record, []
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        add_warning(warnings, f"{appearance}: XCTest attachment manifest could not be read: {error}")
        return test_record, []
    if not isinstance(manifest, list):
        add_warning(warnings, f"{appearance}: XCTest attachment manifest has an unsupported shape.")
        return test_record, []

    test_record["manifestAvailable"] = True
    return test_record, manifest


def matching_attachments(manifest: list[dict], attachment_name: str) -> list[dict]:
    matches = []
    for configuration in manifest:
        if not isinstance(configuration, dict):
            continue
        for attachment in configuration.get("attachments", []):
            if not isinstance(attachment, dict):
                continue
            suggested = attachment.get("suggestedHumanReadableName", "")
            if isinstance(suggested, str) and suggested.startswith(attachment_name + "_") \
                    and suggested.lower().endswith(".png"):
                matches.append(attachment)
    matches.sort(key=lambda item: (
        item.get("timestamp") if isinstance(item.get("timestamp"), (int, float)) else float("-inf"),
        str(item.get("exportedFileName", "")),
    ))
    return matches


def png_dimensions(data: bytes) -> tuple[int, int] | None:
    if len(data) < 24 or not data.startswith(PNG_SIGNATURE):
        return None
    try:
        return struct.unpack(">II", data[16:24])
    except struct.error:
        return None


def missing_capture(slug: str, title: str, appearance: str, reason: str) -> dict:
    return {
        "screen": slug,
        "screenTitle": title,
        "appearance": appearance,
        "status": "missing",
        "verification": "unverified",
        "file": None,
        "orientation": None,
        "width": None,
        "height": None,
        "sha256": None,
        "reasons": [reason],
    }


def capture_available_image(slug: str, title: str, attachment_name: str,
                            appearance: str, matches: list[dict], export_dir: Path,
                            captures_dir: Path, appearance_set: bool,
                            test_record: dict, warnings: list[str]) -> dict:
    if not matches:
        reason = "No matching screenshot attachment was exported."
        add_warning(warnings, f"{title}, {appearance}: {reason}")
        return missing_capture(slug, title, appearance, reason)

    attachment = matches[-1]
    reasons = []
    if len(matches) > 1:
        reasons.append(f"Found {len(matches)} matching attachments; using the newest.")
    if not appearance_set:
        reasons.append(f"Could not verify that {appearance} appearance was set.")
    if test_record.get("testPassed") is not True:
        if test_record.get("testPassed") is False:
            reasons.append("The targeted UI test did not pass.")
        else:
            reasons.append("The targeted UI test result is unavailable.")
    if attachment.get("isAssociatedWithFailure") is True:
        reasons.append("The screenshot is associated with a test failure.")

    exported_name = attachment.get("exportedFileName")
    if not isinstance(exported_name, str) or not exported_name:
        reason = "The attachment has no exported file name."
        add_warning(warnings, f"{title}, {appearance}: {reason}")
        return missing_capture(slug, title, appearance, reason)

    source_file = export_dir / exported_name
    try:
        data = source_file.read_bytes()
    except OSError as error:
        reason = f"The exported screenshot is unavailable: {error}"
        add_warning(warnings, f"{title}, {appearance}: {reason}")
        return missing_capture(slug, title, appearance, reason)

    dimensions = png_dimensions(data)
    if dimensions is None:
        reason = "The exported attachment is not a readable PNG."
        add_warning(warnings, f"{title}, {appearance}: {reason}")
        return missing_capture(slug, title, appearance, reason)

    width, height = dimensions
    orientation = "portrait" if height > width else "landscape" if width > height else "square"
    if orientation != "portrait":
        reasons.append(f"Image dimensions indicate {orientation}, not portrait.")
    suffix = "portrait" if orientation == "portrait" else "orientation-unverified"
    filename = f"{slug}-{suffix}-{appearance}.png"
    relative_path = Path("captures") / filename
    destination = captures_dir / filename
    try:
        shutil.copyfile(source_file, destination)
    except OSError as error:
        reason = f"Could not copy the available screenshot into the page: {error}"
        add_warning(warnings, f"{title}, {appearance}: {reason}")
        return missing_capture(slug, title, appearance, reason)

    capture_time = None
    timestamp = attachment.get("timestamp")
    if isinstance(timestamp, (int, float)):
        try:
            capture_time = dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat().replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError):
            reasons.append("Attachment timestamp is unavailable.")
    else:
        reasons.append("Attachment timestamp is unavailable.")

    if reasons:
        verification = "unverified"
        add_warning(warnings, f"{title}, {appearance}: " + " ".join(reasons))
    else:
        verification = "verified"

    return {
        "screen": slug,
        "screenTitle": title,
        "appearance": appearance,
        "status": "captured",
        "verification": verification,
        "file": relative_path.as_posix(),
        "orientation": orientation,
        "orientationVerified": orientation == "portrait",
        "appearanceSet": appearance_set,
        "testPassed": test_record.get("testPassed"),
        "attachmentCount": len(matches),
        "isAssociatedWithFailure": attachment.get("isAssociatedWithFailure") is True,
        "captureTimestampUTC": capture_time,
        "deviceId": attachment.get("deviceId"),
        "deviceName": attachment.get("deviceName"),
        "sourceAttachment": exported_name,
        "suggestedName": attachment.get("suggestedHumanReadableName"),
        "sha256": hashlib.sha256(data).hexdigest(),
        "width": width,
        "height": height,
        "reasons": reasons,
    }


def read_portrait_support(warnings: list[str]) -> tuple[str, list[str] | None]:
    app_path = ROOT / "DerivedData" / "Build" / "Products" / "Debug-iphonesimulator" / "Harklight.app"
    try:
        with (app_path / "Info.plist").open("rb") as info_file:
            app_info = plistlib.load(info_file)
    except (OSError, plistlib.InvalidFileException, ValueError, TypeError) as error:
        add_warning(warnings, f"Built-app portrait support could not be read: {error}")
        return "unknown", None

    if not isinstance(app_info, dict):
        add_warning(warnings, "Built-app Info.plist has an unsupported shape; portrait support is unknown.")
        return "unknown", None

    raw_orientations = app_info.get("UISupportedInterfaceOrientations")
    if not isinstance(raw_orientations, list):
        add_warning(warnings, "Built-app supported orientations are unavailable; portrait support is unknown.")
        return "unknown", None

    orientations = [
        item for item in raw_orientations
        if isinstance(item, str)
    ]
    if "UIInterfaceOrientationPortrait" not in orientations:
        add_warning(warnings, "The built app does not declare portrait support; captured orientation is unverified.")
        return "not declared", orientations
    return "declared", orientations


def format_duration(seconds: int) -> str:
    hours, remainder = divmod(max(0, seconds), 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def build_html(title: str, revision: str | None, pushed_at: dt.datetime,
               ready_at: dt.datetime, simulator_label: str,
               capture_matrix: dict[tuple[str, str], dict],
               warnings: list[str], timing_status: str,
               elapsed_seconds: int | None, portrait_support: str) -> str:
    sections = []
    for slug, (screen_title, _) in TEST_LABELS.items():
        appearance_items = []
        for appearance in APPEARANCES:
            capture = capture_matrix[(slug, appearance)]
            if capture["status"] == "captured":
                file_path = html.escape(capture["file"], quote=True)
                label = f"{appearance.capitalize()} capture · {capture['verification']}"
                details = [
                    f"{capture['orientation']} image, {capture['width']}×{capture['height']}",
                ]
                if capture.get("reasons"):
                    details.extend(capture["reasons"])
                if capture.get("captureTimestampUTC"):
                    details.append(f"captured {capture['captureTimestampUTC']}")
                appearance_items.append(
                    f'''<div class="appearance-content" data-appearance="{appearance}">
  <img class="capture" src="{file_path}" alt="{html.escape(screen_title)}, {appearance} appearance">
  <p class="capture-status"><strong>{html.escape(label)}.</strong> {html.escape("; ".join(details))}</p>
</div>'''
                )
            else:
                reason = "; ".join(capture.get("reasons", [])) or "Capture unavailable."
                appearance_items.append(
                    f'''<div class="appearance-content unavailable" data-appearance="{appearance}" role="status">
  <strong>{appearance.capitalize()} capture unavailable.</strong> {html.escape(reason)}
</div>'''
                )
        sections.append(
            f'''<section aria-labelledby="screen-{slug}">
  <h2 id="screen-{slug}">{html.escape(screen_title)}</h2>
  <figure class="card">{''.join(appearance_items)}
    <figcaption>Requested orientation: portrait · fold state not recorded</figcaption>
  </figure>
</section>'''
        )

    if elapsed_seconds is None:
        timing_text = "Change-to-page time is uncertain; see the warning below."
    else:
        timing_text = f"Change-to-page time: {format_duration(elapsed_seconds)}"

    warning_html = ""
    if warnings:
        warning_html = (
            '<aside class="warnings"><h2>Capture notes</h2><ul>'
            + "".join(f"<li>{html.escape(item)}</li>" for item in warnings)
            + "</ul></aside>"
        )
    revision_text = revision or "Unknown"
    ready_text = ready_at.strftime("%Y-%m-%d %H:%M UTC")
    pushed_text = pushed_at.strftime("%Y-%m-%d %H:%M UTC")
    image_count = sum(item["status"] == "captured" for item in capture_matrix.values())
    verified_count = sum(item["verification"] == "verified" for item in capture_matrix.values())

    return f'''<!doctype html>
<html lang="en" data-appearance="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    :root {{ color-scheme: light; --background:#f4f5f7; --surface:#fff; --text:#20242b; --muted:#626b77; --border:#d7dce2; }}
    :root[data-appearance="dark"] {{ color-scheme: dark; --background:#171a1f; --surface:#22272f; --text:#edf0f3; --muted:#aeb7c2; --border:#414955; }}
    * {{ box-sizing: border-box; }}
    body {{ margin:0; background:var(--background); color:var(--text); font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
    header {{ position:sticky; top:0; z-index:1; display:flex; align-items:center; justify-content:space-between; gap:24px; padding:18px clamp(16px,4vw,48px); border-bottom:1px solid var(--border); background:var(--surface); }}
    h1 {{ margin:0 0 4px; font-size:clamp(20px,3vw,28px); }}
    h2 {{ margin:28px 0 12px; font-size:20px; }}
    p {{ margin:3px 0; color:var(--muted); }}
    main {{ max-width:1100px; margin:0 auto; padding:0 clamp(16px,4vw,48px) 40px; }}
    .scope, .warnings {{ margin:18px 0 26px; padding:14px 16px; border:1px solid var(--border); border-radius:10px; background:var(--surface); }}
    .warnings {{ border-color:#b87925; }}
    .warnings ul {{ margin-bottom:0; padding-left:22px; }}
    .card {{ margin:0; overflow:hidden; border:1px solid var(--border); border-radius:12px; background:var(--surface); }}
    .appearance-content {{ padding:12px; }}
    .capture {{ display:block; max-width:100%; max-height:72vh; margin:0 auto; object-fit:contain; border-radius:8px; }}
    .capture-status {{ padding:10px 2px 0; }}
    .unavailable {{ min-height:120px; display:flex; align-items:center; gap:8px; color:var(--muted); }}
    :root[data-appearance="light"] .appearance-content[data-appearance="dark"], :root[data-appearance="dark"] .appearance-content[data-appearance="light"] {{ display:none; }}
    figcaption {{ padding:10px 12px; border-top:1px solid var(--border); color:var(--muted); }}
    code {{ overflow-wrap:anywhere; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }}
    .switch {{ display:inline-flex; align-items:center; gap:10px; min-width:max-content; cursor:pointer; }}
    .switch input {{ width:44px; height:24px; margin:0; accent-color:#3578d4; cursor:pointer; }}
    @media(max-width:620px) {{ header {{ align-items:flex-start; flex-direction:column; gap:12px; }} }}
  </style>
</head>
<body>
  <header><div>
    <h1>{html.escape(title)}</h1>
    <p>Simulator captures · {html.escape(simulator_label)}</p>
    <p>Revision <code>{html.escape(revision_text)}</code> · pushed {pushed_text} · page ready {ready_text}</p>
    <p>{html.escape(timing_text)}</p>
    <p>{image_count} of {len(capture_matrix)} images available · {verified_count} verified</p>
  </div><label class="switch" for="appearance-switch">
    <input id="appearance-switch" type="checkbox" role="switch" aria-label="Show dark appearance">
    <span>Dark appearance</span>
  </label></header>
  <main>
    <p class="scope"><strong>Capture scope:</strong> Inbox and selected message detail, portrait requested, light and dark. Fold state was not observed or changed. Missing or unverified captures are labeled. Built-app portrait support: {html.escape(portrait_support)}. Landscape and fold coverage are excluded.</p>
    {warning_html}
    {''.join(sections)}
  </main>
  <script>
    const toggle = document.getElementById("appearance-switch");
    toggle.addEventListener("change", () => {{ document.documentElement.dataset.appearance = toggle.checked ? "dark" : "light"; }});
  </script>
</body>
</html>
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--page-dir", required=True, help="New output directory; it must not already exist.")
    parser.add_argument("--page-title", required=True, help="Short review title for this iteration.")
    parser.add_argument("--pushed-at", required=True, help="UTC ISO 8601 timestamp for the change push.")
    parser.add_argument("--device-id", default=os.environ.get("HARKLIGHT_SIMULATOR_ID"),
                        help="Booted simulator UUID; defaults to HARKLIGHT_SIMULATOR_ID.")
    args = parser.parse_args()

    try:
        if not args.device_id:
            raise CaptureError("Set HARKLIGHT_SIMULATOR_ID to the booted simulator UUID.")
        if not args.page_title.strip():
            raise CaptureError("--page-title cannot be empty.")
        pushed_at = parse_timestamp(args.pushed_at)
        simulator_name = find_simulator(args.device_id)
        simulator_label = simulator_name or f"Simulator {args.device_id}"

        page_dir = Path(args.page_dir).expanduser().resolve()
        if page_dir.exists():
            raise CaptureError(f"Output directory already exists: {page_dir}")
        page_dir.mkdir(parents=True, exist_ok=False)
        captures_dir = page_dir / "captures"
        provenance_dir = page_dir / "provenance"
        captures_dir.mkdir()
        provenance_dir.mkdir()

        warnings: list[str] = []
        revision_result = attempt(["git", "rev-parse", "HEAD"])
        revision = None
        if revision_result["error"] or revision_result["returnCode"] != 0:
            add_warning(warnings, "Source revision could not be read; source provenance is unknown.")
        else:
            revision = revision_result["output"].strip()

        appearance_query = attempt([
            "xcrun", "simctl", "ui", args.device_id, "appearance",
        ])
        original_appearance_raw = appearance_query["output"].strip() if appearance_query["returnCode"] == 0 else None
        original_appearance = original_appearance_raw if original_appearance_raw in APPEARANCES else None
        if original_appearance is None:
            add_warning(
                warnings,
                "The simulator's original appearance is unknown; its appearance will not be restored.",
            )

        capture_matrix: dict[tuple[str, str], dict] = {}
        test_records = []
        appearance_set_records = []

        try:
            for appearance in APPEARANCES:
                set_result = attempt([
                    "xcrun", "simctl", "ui", args.device_id, "appearance", appearance,
                ])
                appearance_set = set_result["returnCode"] == 0 and set_result["error"] is None
                if not appearance_set:
                    reason = set_result["error"] or f"simctl could not set {appearance} appearance."
                    add_warning(warnings, f"{appearance}: {reason}")

                export_dir = provenance_dir / f"{appearance}-attachments"
                try:
                    test_record, manifest = run_capture_test(
                        args.device_id, appearance, export_dir, warnings,
                    )
                except Exception as error:
                    add_warning(
                        warnings,
                        f"{appearance}: capture collection failed; available screenshots will be marked unverified: {error}",
                    )
                    test_record, manifest = {
                        "appearance": appearance,
                        "wrapperExitCode": None,
                        "wrapperError": str(error),
                        "result": None,
                        "passedTests": None,
                        "failedTests": None,
                        "testPassed": None,
                        "resultBundle": None,
                        "attachmentExportExitCode": None,
                        "manifestAvailable": False,
                    }, []
                test_record["appearanceSet"] = appearance_set
                test_records.append(test_record)
                appearance_set_records.append({
                    "appearance": appearance,
                    "setSucceeded": appearance_set,
                    "setError": set_result["error"],
                    "setExitCode": set_result["returnCode"],
                })

                for slug, (screen_title, attachment_name) in TEST_LABELS.items():
                    try:
                        matches = matching_attachments(manifest, attachment_name)
                        capture_matrix[(slug, appearance)] = capture_available_image(
                            slug, screen_title, attachment_name, appearance, matches,
                            export_dir, captures_dir, appearance_set, test_record, warnings,
                        )
                    except Exception as error:
                        reason = f"Capture processing did not complete: {error}"
                        add_warning(warnings, f"{screen_title}, {appearance}: {reason}")
                        capture_matrix[(slug, appearance)] = missing_capture(
                            slug, screen_title, appearance, reason,
                        )
        finally:
            if original_appearance is not None:
                restore_result = attempt([
                    "xcrun", "simctl", "ui", args.device_id, "appearance", original_appearance,
                ])
                if restore_result["returnCode"] == 0 and restore_result["error"] is None:
                    restore_status = "restored"
                else:
                    restore_status = "failed"
                    reason = restore_result["error"] or "simctl could not restore the original appearance."
                    add_warning(warnings, reason)
            else:
                restore_status = "skipped_unknown"

        portrait_support, supported_orientations = read_portrait_support(warnings)
        for capture in capture_matrix.values():
            if capture["status"] != "captured":
                continue
            if portrait_support != "declared":
                reason = f"Built-app portrait support is {portrait_support}."
                if reason not in capture["reasons"]:
                    capture["reasons"].append(reason)
                    capture["verification"] = "unverified"

        ready_at = dt.datetime.now(dt.timezone.utc)
        elapsed = int((ready_at - pushed_at).total_seconds())
        if elapsed < 0:
            add_warning(warnings, "The supplied push timestamp is later than page readiness; elapsed time is uncertain.")
            elapsed_seconds = None
            timing_status = "uncertain-future-push-time"
        else:
            elapsed_seconds = elapsed
            timing_status = "measured"

        page_html = build_html(
            args.page_title, revision, pushed_at, ready_at, simulator_label,
            capture_matrix, warnings, timing_status, elapsed_seconds, portrait_support,
        )
        (page_dir / "index.html").write_text(page_html, encoding="utf-8")

        capture_records = list(capture_matrix.values())
        available_count = sum(item["status"] == "captured" for item in capture_records)
        verified_count = sum(item["verification"] == "verified" for item in capture_records)
        page_status = "complete" if verified_count == len(capture_records) else (
            "partial" if available_count else "unavailable"
        )
        actual_orientations = sorted({
            item["orientation"] for item in capture_records
            if item["status"] == "captured" and item.get("orientation")
        })
        metadata = {
            "pageTitle": args.page_title,
            "sourceRevision": revision,
            "simulator": {
                "name": simulator_name,
                "displayName": simulator_label,
                "id": args.device_id,
            },
            "pushedAtUTC": timestamp_text(pushed_at),
            "pageReadyAtUTC": timestamp_text(ready_at),
            "changeToPageSeconds": elapsed_seconds,
            "timingStatus": timing_status,
            "capturedOrientations": actual_orientations,
            "supportedOrientations": supported_orientations,
            "portraitSupportStatus": portrait_support,
            "foldState": "not observed or changed",
            "foldCoverage": "excluded",
            "pageStatus": page_status,
            "imageCount": available_count,
            "verifiedImageCount": verified_count,
            "appearances": {
                "requested": list(APPEARANCES),
                "original": original_appearance,
                "originalRaw": original_appearance_raw,
                "setRequests": appearance_set_records,
                "restoreStatus": restore_status,
            },
            "captureWrapper": "Scripts/verify.sh test (unchanged), targeted through HARKLIGHT_ONLY_TESTING",
            "captureTest": TEST_ID,
            "tests": test_records,
            "captureMatrix": capture_records,
            "captures": [item for item in capture_records if item["status"] == "captured"],
            "warnings": warnings,
        }
        (page_dir / "metadata.json").write_text(
            json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

        if elapsed_seconds is None:
            print("Change-to-page time is uncertain; see page notes.")
        else:
            print(f"Change-to-page time: {format_duration(elapsed_seconds)}")
        print(f"Page ready ({page_status}): {page_dir / 'index.html'}")
        print(f"Captured {available_count} of {len(capture_records)} images; {verified_count} verified.")
        print(f"Source revision: {revision or 'unknown'}")
        print(f"Capture report: {page_dir / 'metadata.json'}")
        return 0
    except (CaptureError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"capture-preview-page: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("capture-preview-page: cancelled; any exported attachments remain in the page folder.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
