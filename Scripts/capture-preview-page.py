#!/usr/bin/env python3
"""Capture a portrait Harklight preview page from targeted simulator UI screenshots."""

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
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEST_ID = "HarklightUITests/SampleWorkspaceUITests/testPreviewPageCapturesInboxAndDetail"
TEST_LABELS = {
    "inbox": ("Inbox", "preview-portrait-inbox"),
    "detail": ("Message detail", "preview-portrait-detail"),
}
APPEARANCES = ("light", "dark")


class CaptureError(RuntimeError):
    pass


def run(command: list[str], *, capture_output: bool = False,
        env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        command, cwd=ROOT, env=env, check=False, text=True,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.STDOUT if capture_output else None,
    )
    if result.returncode != 0:
        detail = result.stdout if capture_output else ""
        raise CaptureError(
            f"Command failed ({result.returncode}): {' '.join(command)}"
            + (f"\n{detail[-12000:]}" if detail else "")
        )
    return result.stdout.strip() if capture_output else ""


def parse_timestamp(value: str) -> dt.datetime:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise CaptureError("--pushed-at must be an ISO 8601 timestamp with a timezone.") from error
    if parsed.tzinfo is None:
        raise CaptureError("--pushed-at must include a timezone, for example 2026-10-23T15:12:00Z.")
    return parsed.astimezone(dt.timezone.utc)


def find_simulator(device_id: str) -> str:
    raw = run(["xcrun", "simctl", "list", "devices", "--json"], capture_output=True)
    devices = json.loads(raw).get("devices", {})
    for runtime_devices in devices.values():
        for device in runtime_devices:
            if device.get("udid") == device_id:
                name = device.get("name", "")
                if device.get("state") != "Booted":
                    raise CaptureError(f"Simulator {name!r} is not booted.")
                if "duo" not in name.lower():
                    raise CaptureError(f"Simulator {name!r} is not an iPhone Duo simulator.")
                return name
    raise CaptureError("HARKLIGHT_SIMULATOR_ID does not name an available simulator on this Mac.")


def result_bundles() -> set[Path]:
    directory = ROOT / "DerivedData" / "Logs" / "Test"
    return {path.resolve() for path in directory.glob("*.xcresult")}


def run_capture_test(device_id: str, appearance: str, export_dir: Path) -> tuple[dict, Path]:
    before = result_bundles()
    env = os.environ.copy()
    env["HARKLIGHT_SIMULATOR_ID"] = device_id
    env["HARKLIGHT_ONLY_TESTING"] = TEST_ID
    print(f"Capturing the Inbox and selected detail in {appearance} appearance…", flush=True)
    output = run([str(ROOT / "Scripts" / "verify.sh"), "test"], capture_output=True, env=env)
    new_bundles = sorted(
        (path for path in result_bundles() - before if path.exists()),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not new_bundles:
        matches = re.findall(r"(/[^\r\n]*?\.xcresult)", output)
        for match in reversed(matches):
            candidate = Path(match.rstrip(" .,:;")).resolve()
            if candidate.exists():
                new_bundles.append(candidate)
                break
    if not new_bundles:
        raise CaptureError("The wrapper passed but no new Xcode result bundle could be located.")
    result_bundle = new_bundles[0]
    summary_text = run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_bundle)],
        capture_output=True,
    )
    summary = json.loads(summary_text)
    if summary.get("result") != "Passed" or summary.get("failedTests") != 0:
        raise CaptureError(f"The targeted capture UI test did not pass: {summary_text}")
    export_dir.mkdir(parents=True, exist_ok=False)
    run([
        "xcrun", "xcresulttool", "export", "attachments",
        "--path", str(result_bundle), "--output-path", str(export_dir),
    ])
    manifest_path = export_dir / "manifest.json"
    if not manifest_path.is_file():
        raise CaptureError(f"XCTest attachment manifest is missing at {manifest_path}.")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    return {"summary": summary, "manifest": manifest}, result_bundle


def select_attachment(manifest: list[dict], attachment_name: str) -> dict:
    matches = []
    for configuration in manifest:
        for attachment in configuration.get("attachments", []):
            suggested = attachment.get("suggestedHumanReadableName", "")
            if suggested.startswith(attachment_name + "_") and suggested.lower().endswith(".png"):
                matches.append(attachment)
    if len(matches) != 1:
        raise CaptureError(
            f"Expected one screenshot named {attachment_name!r}; found {len(matches)}."
        )
    return matches[0]


def format_duration(seconds: int) -> str:
    hours, remainder = divmod(max(0, seconds), 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def build_html(title: str, revision: str, pushed_at: dt.datetime,
               ready_at: dt.datetime, simulator_name: str,
               screenshots: dict[str, dict[str, str]]) -> str:
    elapsed = int((ready_at - pushed_at).total_seconds())
    sections = []
    for slug, (screen_title, _) in TEST_LABELS.items():
        light_path = html.escape(screenshots[slug]["light"], quote=True)
        dark_path = html.escape(screenshots[slug]["dark"], quote=True)
        sections.append(
            f'''<section aria-labelledby="screen-{slug}">
  <h2 id="screen-{slug}">{html.escape(screen_title)}</h2>
  <figure class="card"><div class="image-frame">
    <img class="capture" data-appearance="light" src="{light_path}" alt="{html.escape(screen_title)}, portrait, light appearance">
    <img class="capture" data-appearance="dark" src="{dark_path}" alt="{html.escape(screen_title)}, portrait, dark appearance">
  </div><figcaption>Portrait · fold state not recorded</figcaption></figure>
</section>'''
        )
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
    .scope {{ margin:18px 0 26px; padding:14px 16px; border:1px solid var(--border); border-radius:10px; background:var(--surface); }}
    .card {{ margin:0; overflow:hidden; border:1px solid var(--border); border-radius:12px; background:var(--surface); }}
    .image-frame {{ display:grid; place-items:center; min-height:180px; padding:12px; }}
    .capture {{ display:block; max-width:100%; max-height:72vh; object-fit:contain; border-radius:8px; }}
    :root[data-appearance="light"] .capture[data-appearance="dark"], :root[data-appearance="dark"] .capture[data-appearance="light"] {{ display:none; }}
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
    <p>Simulator captures · {html.escape(simulator_name)}</p>
    <p>Revision <code>{html.escape(revision)}</code> · pushed {pushed_at.strftime('%Y-%m-%d %H:%M UTC')} · page ready {ready_at.strftime('%Y-%m-%d %H:%M UTC')}</p>
    <p>Change-to-page time: {format_duration(elapsed)}</p>
  </div><label class="switch" for="appearance-switch">
    <input id="appearance-switch" type="checkbox" role="switch" aria-label="Show dark appearance">
    <span>Dark appearance</span>
  </label></header>
  <main>
    <p class="scope"><strong>Capture scope:</strong> Inbox and selected message detail, portrait only, light and dark. Fold state was not observed or changed. Landscape and fold coverage are excluded.</p>
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
    parser.add_argument("--page-dir", required=True, help="New output directory outside the source repository.")
    parser.add_argument("--page-title", required=True, help="Short review title for this iteration.")
    parser.add_argument("--pushed-at", required=True, help="UTC ISO 8601 timestamp for the change push.")
    parser.add_argument("--device-id", default=os.environ.get("HARKLIGHT_SIMULATOR_ID"),
                        help="Booted iPhone Duo simulator UUID; defaults to HARKLIGHT_SIMULATOR_ID.")
    args = parser.parse_args()

    try:
        if not args.device_id:
            raise CaptureError("Set HARKLIGHT_SIMULATOR_ID to the booted iPhone Duo simulator UUID.")
        if not args.page_title.strip():
            raise CaptureError("--page-title cannot be empty.")
        pushed_at = parse_timestamp(args.pushed_at)
        simulator_name = find_simulator(args.device_id)
        page_dir = Path(args.page_dir).expanduser().resolve()
        try:
            page_dir.relative_to(ROOT.resolve())
        except ValueError:
            pass
        else:
            raise CaptureError("Keep generated preview pages outside the public source repository.")
        if page_dir.exists():
            raise CaptureError(f"Output directory already exists: {page_dir}")
        page_dir.parent.mkdir(parents=True, exist_ok=True)

        revision = run(["git", "rev-parse", "HEAD"], capture_output=True)
        original_appearance = run(
            ["xcrun", "simctl", "ui", args.device_id, "appearance"], capture_output=True
        )
        if original_appearance not in APPEARANCES:
            raise CaptureError(f"Simulator returned an unknown appearance: {original_appearance!r}.")
        staging_dir = Path(tempfile.mkdtemp(prefix=".preview-page-", dir=page_dir.parent))
        (staging_dir / "captures").mkdir()
        (staging_dir / "provenance").mkdir()
        screenshot_map: dict[str, dict[str, str]] = {slug: {} for slug in TEST_LABELS}
        attachment_records = []
        test_records = []
        elapsed = 0
        try:
            for appearance in APPEARANCES:
                run(["xcrun", "simctl", "ui", args.device_id, "appearance", appearance])
                export_dir = staging_dir / "provenance" / f"{appearance}-attachments"
                capture_data, result_bundle = run_capture_test(args.device_id, appearance, export_dir)
                summary = capture_data["summary"]
                test_records.append({
                    "appearance": appearance,
                    "result": summary.get("result"),
                    "passedTests": summary.get("passedTests"),
                    "failedTests": summary.get("failedTests"),
                    "resultBundle": str(result_bundle),
                })
                for slug, (screen_title, attachment_name) in TEST_LABELS.items():
                    attachment = select_attachment(capture_data["manifest"], attachment_name)
                    source_file = export_dir / attachment["exportedFileName"]
                    if not source_file.is_file():
                        raise CaptureError(f"Exported screenshot is missing: {source_file}.")
                    data = source_file.read_bytes()
                    width, height = struct.unpack(">II", data[16:24])
                    if height <= width:
                        raise CaptureError(
                            f"{attachment_name} screenshot is not portrait-shaped ({width}×{height})."
                        )
                    if attachment.get("isAssociatedWithFailure"):
                        raise CaptureError(f"{attachment_name} screenshot is associated with a test failure.")
                    filename = f"{slug}-portrait-{appearance}.png"
                    relative_path = Path("captures") / filename
                    destination = staging_dir / relative_path
                    shutil.copyfile(source_file, destination)
                    screenshot_map[slug][appearance] = relative_path.as_posix()
                    attachment_records.append({
                        "screen": slug,
                        "screenTitle": screen_title,
                        "orientation": "portrait",
                        "appearance": appearance,
                        "captureTimestampUTC": dt.datetime.fromtimestamp(
                            attachment["timestamp"], dt.timezone.utc
                        ).isoformat().replace("+00:00", "Z"),
                        "deviceId": attachment.get("deviceId"),
                        "deviceName": attachment.get("deviceName"),
                        "sourceAttachment": attachment.get("exportedFileName"),
                        "suggestedName": attachment.get("suggestedHumanReadableName"),
                        "file": relative_path.as_posix(),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "width": width,
                        "height": height,
                    })
            app_path = ROOT / "DerivedData" / "Build" / "Products" / "Debug-iphonesimulator" / "Harklight.app"
            with (app_path / "Info.plist").open("rb") as info_file:
                supported_orientations = plistlib.load(info_file).get("UISupportedInterfaceOrientations", [])
            if "UIInterfaceOrientationPortrait" not in supported_orientations:
                raise CaptureError("The built app does not declare portrait orientation support.")

            ready_at = dt.datetime.now(dt.timezone.utc)
            elapsed = int((ready_at - pushed_at).total_seconds())
            if elapsed < -5:
                raise CaptureError("The supplied push time is more than five seconds in the future.")
            page_html = build_html(args.page_title, revision, pushed_at, ready_at,
                                   simulator_name, screenshot_map)
            (staging_dir / "index.html").write_text(page_html, encoding="utf-8")
            metadata = {
                "pageTitle": args.page_title,
                "sourceRevision": revision,
                "simulator": {"name": simulator_name, "id": args.device_id},
                "pushedAtUTC": pushed_at.isoformat().replace("+00:00", "Z"),
                "pageReadyAtUTC": ready_at.isoformat().replace("+00:00", "Z"),
                "changeToPageSeconds": max(0, elapsed),
                "capturedOrientations": ["portrait"],
                "supportedOrientations": [
                    "portrait" if name == "UIInterfaceOrientationPortrait" else name
                    for name in supported_orientations
                ],
                "foldState": "not observed or changed",
                "foldCoverage": "excluded",
                "appearances": list(APPEARANCES),
                "captureWrapper": "Scripts/verify.sh test (unchanged), targeted through HARKLIGHT_ONLY_TESTING",
                "captureTest": TEST_ID,
                "appearanceControl": "xcrun simctl ui <simulator-id> appearance <light|dark>; original appearance restored after capture",
                "tests": test_records,
                "captures": attachment_records,
            }
            (staging_dir / "metadata.json").write_text(
                json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
            staging_dir.rename(page_dir)
        finally:
            subprocess.run([
                "xcrun", "simctl", "ui", args.device_id, "appearance", original_appearance
            ], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if staging_dir.exists():
                shutil.rmtree(staging_dir)

        print(f"Page ready: {page_dir / 'index.html'}")
        print(f"Source revision: {revision}")
        print(f"Change-to-page time: {format_duration(max(0, elapsed))}")
        print(f"Capture report: {page_dir / 'metadata.json'}")
        return 0
    except (CaptureError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"capture-preview-page: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("capture-preview-page: cancelled", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
