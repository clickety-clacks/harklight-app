#!/usr/bin/env python3
"""Build and capture a UI preview page from an iPhone Duo simulator."""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "co.clicketyclacks.Harklight"
ORIENTATION_LABELS = {
    "UIInterfaceOrientationPortrait": ("portrait", "Portrait"),
    "UIInterfaceOrientationPortraitUpsideDown": ("portrait-upside-down", "Portrait upside down"),
    "UIInterfaceOrientationLandscapeLeft": ("landscape-left", "Landscape left"),
    "UIInterfaceOrientationLandscapeRight": ("landscape-right", "Landscape right"),
}
# The simulator exposes the two displays separately at Apple's published sizes.
DISPLAY_SIZE_CLASSES = {
    (1398, 2034): "outer",
    (2007, 2853): "inner",
}
DISPLAY_PATTERN = re.compile(
    r"Screen ID:\s*(\d+)\s*\n\s*Name:\s*([^\n]+).*?\n\s*Pixel Size:\s*\{\s*(\d+)\s*,\s*(\d+)\s*\}",
    re.DOTALL,
)
POSTURES = (
    ("open", "Open"),
    ("partly-folded", "Partly folded"),
    ("closed-outer", "Closed · outer display"),
)
APPEARANCES = ("light", "dark")
SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class CaptureError(RuntimeError):
    pass


def run(command: list[str], *, capture_output: bool = False,
        env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.PIPE if capture_output else None,
    )
    if result.returncode != 0:
        detail = ""
        if capture_output:
            detail = "\n".join(part for part in (result.stdout, result.stderr) if part)
        raise CaptureError(f"Command failed ({result.returncode}): {' '.join(command)}\n{detail}")
    return result.stdout.strip() if capture_output else ""


def parse_pushed_at(value: str) -> dt.datetime:
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


def simulator_displays(device_id: str) -> dict[str, str]:
    raw = run(["xcrun", "simctl", "io", device_id, "enumerate"], capture_output=True)
    displays: dict[str, str] = {}
    for match in DISPLAY_PATTERN.finditer(raw):
        screen_id, _name, width, height = match.groups()
        size_class = DISPLAY_SIZE_CLASSES.get(tuple(sorted((int(width), int(height)))))
        if size_class:
            if size_class in displays:
                raise CaptureError(f"The simulator reported multiple {size_class} displays; refusing an ambiguous capture.")
            displays[size_class] = screen_id
    missing = {"inner", "outer"} - displays.keys()
    if missing:
        raise CaptureError("The simulator did not report both iPhone Duo displays; missing: " + ", ".join(sorted(missing)))
    return displays


def parse_screen(value: str) -> tuple[str, str]:
    slug, separator, title = value.partition("=")
    if not separator or not SLUG_PATTERN.fullmatch(slug) or not title.strip():
        raise CaptureError(f"Invalid screen {value!r}; use a lowercase slug and title, such as inbox=Inbox.")
    return slug, title.strip()


def parse_screens(values: list[str]) -> list[tuple[str, str]]:
    if not values:
        raise CaptureError("Add at least one --screen SLUG=TITLE for each changed screen.")
    screens = [parse_screen(value) for value in values]
    slugs = [slug for slug, _ in screens]
    if len(slugs) != len(set(slugs)):
        raise CaptureError("Each changed screen needs a unique slug.")
    return screens


def supported_orientations(app_path: Path) -> tuple[tuple[str, str], ...]:
    with (app_path / "Info.plist").open("rb") as info_file:
        info = plistlib.load(info_file)
    names = info.get("UISupportedInterfaceOrientations", [])
    orientations = tuple(ORIENTATION_LABELS[name] for name in names if name in ORIENTATION_LABELS)
    if not orientations:
        raise CaptureError("The built app does not declare any supported iPhone interface orientations.")
    return orientations


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
               screens: list[tuple[str, str]], captures: list[dict[str, str]]) -> str:
    elapsed = int((ready_at - pushed_at).total_seconds())
    cards: list[str] = []
    for capture in captures:
        alt_base = " · ".join((capture["screenTitle"], capture["postureTitle"],
                               capture["orientationTitle"]))
        images = "".join(
            "<img class=\"capture\" data-appearance=\"{appearance}\" src=\"{src}\" alt=\"{alt}\">".format(
                appearance=html.escape(appearance),
                src=html.escape(capture[appearance], quote=True),
                alt=html.escape(f"{alt_base} · {appearance.title()} appearance", quote=True),
            )
            for appearance in APPEARANCES
        )
        cards.append(
            "<figure class=\"card\"><div class=\"image-frame\">{images}</div>"
            "<figcaption><strong>{screen}</strong><span>{posture} · {orientation}</span></figcaption></figure>".format(
                images=images,
                screen=html.escape(capture["screenTitle"]),
                posture=html.escape(capture["postureTitle"]),
                orientation=html.escape(capture["orientationTitle"]),
            )
        )

    screen_sections: list[str] = []
    for slug, screen_title in screens:
        screen_cards = [card for card, capture in zip(cards, captures) if capture["screen"] == slug]
        screen_sections.append(
            "<section class=\"screen\" aria-labelledby=\"screen-{slug}\">"
            "<h2 id=\"screen-{slug}\">{title}</h2><div class=\"grid\">{cards}</div></section>".format(
                slug=html.escape(slug, quote=True),
                title=html.escape(screen_title),
                cards="".join(screen_cards),
            )
        )

    return """<!doctype html>
<html lang="en" data-appearance="light">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <style>
    :root {{ color-scheme: light; --background: #f4f5f7; --surface: #fff; --text: #20242b; --muted: #626b77; --border: #d7dce2; }}
    :root[data-appearance="dark"] {{ color-scheme: dark; --background: #171a1f; --surface: #22272f; --text: #edf0f3; --muted: #aeb7c2; --border: #414955; }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: var(--background); color: var(--text); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
    header {{ position: sticky; top: 0; z-index: 1; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 18px clamp(16px, 4vw, 48px); border-bottom: 1px solid var(--border); background: var(--surface); }}
    h1 {{ margin: 0 0 4px; font-size: clamp(20px, 3vw, 28px); }}
    h2 {{ margin: 28px 0 12px; font-size: 20px; }}
    p {{ margin: 3px 0; color: var(--muted); }}
    main {{ max-width: 1440px; margin: 0 auto; padding: 0 clamp(16px, 4vw, 48px) 40px; }}
    .switch {{ display: inline-flex; align-items: center; gap: 10px; min-width: max-content; cursor: pointer; color: var(--text); }}
    .switch input {{ width: 44px; height: 24px; margin: 0; accent-color: #3578d4; cursor: pointer; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 320px), 1fr)); gap: 16px; }}
    .card {{ margin: 0; overflow: hidden; border: 1px solid var(--border); border-radius: 12px; background: var(--surface); }}
    .image-frame {{ display: grid; place-items: center; min-height: 180px; padding: 12px; }}
    .capture {{ display: block; max-width: 100%; max-height: 70vh; object-fit: contain; border-radius: 8px; }}
    :root[data-appearance="light"] .capture[data-appearance="dark"], :root[data-appearance="dark"] .capture[data-appearance="light"] {{ display: none; }}
    figcaption {{ display: flex; justify-content: space-between; gap: 12px; padding: 10px 12px; border-top: 1px solid var(--border); color: var(--muted); }}
    figcaption strong {{ color: var(--text); }}
    code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
    @media (max-width: 620px) {{ header {{ align-items: flex-start; flex-direction: column; gap: 12px; }} figcaption {{ flex-direction: column; gap: 2px; }} }}
  </style>
</head>
<body>
  <header>
    <div>
      <h1>{title}</h1>
      <p>Simulator captures · {simulator}</p>
      <p>Revision <code>{revision}</code> · pushed {pushed} · page ready {ready}</p>
      <p>Change-to-page time: {elapsed}</p>
    </div>
    <label class="switch" for="appearance-switch">
      <input id="appearance-switch" type="checkbox" role="switch" aria-label="Show dark appearance">
      <span>Dark appearance</span>
    </label>
  </header>
  <main>{sections}</main>
  <script>
    const appearanceSwitch = document.getElementById("appearance-switch");
    appearanceSwitch.addEventListener("change", () => {{
      document.documentElement.dataset.appearance = appearanceSwitch.checked ? "dark" : "light";
    }});
  </script>
</body>
</html>
""".format(
        title=html.escape(title),
        simulator=html.escape(simulator_name),
        revision=html.escape(revision),
        pushed=html.escape(pushed_at.strftime("%Y-%m-%d %H:%M UTC")),
        ready=html.escape(ready_at.strftime("%Y-%m-%d %H:%M UTC")),
        elapsed=html.escape(format_duration(elapsed)),
        sections="".join(screen_sections),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--page-dir", required=True, help="New output directory outside the source repository.")
    parser.add_argument("--page-title", required=True, help="Short review title for this iteration.")
    parser.add_argument("--pushed-at", required=True, help="UTC ISO 8601 timestamp for the change push.")
    parser.add_argument("--screen", action="append", default=[], metavar="SLUG=TITLE",
                        help="Changed screen to capture; repeat once per changed screen.")
    parser.add_argument("--device-id", default=os.environ.get("HARKLIGHT_SIMULATOR_ID"),
                        help="Booted iPhone Duo simulator UUID; defaults to HARKLIGHT_SIMULATOR_ID.")
    args = parser.parse_args()

    try:
        if not sys.stdin.isatty():
            raise CaptureError("Run this command in an interactive terminal so each simulator pose can be confirmed.")
        if not args.device_id:
            raise CaptureError("Set HARKLIGHT_SIMULATOR_ID to your booted iPhone Duo simulator UUID.")
        screens = parse_screens(args.screen)
        if not args.page_title.strip():
            raise CaptureError("--page-title cannot be empty.")
        pushed_at = parse_pushed_at(args.pushed_at)
        simulator_name = find_simulator(args.device_id)
        displays = simulator_displays(args.device_id)
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

        revision = run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True)
        build_env = os.environ.copy()
        build_env["HARKLIGHT_SIMULATOR_ID"] = args.device_id
        print("Building the app with the repository wrapper (build only; no test suite).", flush=True)
        run([str(ROOT / "Scripts" / "verify.sh"), "build"], env=build_env)

        app_path = ROOT / "DerivedData" / "Build" / "Products" / "Debug-iphonesimulator" / "Harklight.app"
        if not app_path.is_dir():
            raise CaptureError(f"Build completed but the app was not found at {app_path}.")
        orientations = supported_orientations(app_path)
        run(["xcrun", "simctl", "install", args.device_id, str(app_path)])
        run(["xcrun", "simctl", "launch", "--terminate-running-process", args.device_id,
             BUNDLE_ID, "--reset-attention-fixture", "--harklight-samples"])
        time.sleep(2)

        original_appearance = run(["xcrun", "simctl", "ui", args.device_id, "appearance"], capture_output=True)
        staging_dir = Path(tempfile.mkdtemp(prefix=".preview-page-", dir=page_dir.parent))
        (staging_dir / "captures").mkdir()
        captures: list[dict[str, str]] = []
        try:
            for screen_slug, screen_title in screens:
                input(f"Navigate the app to the changed screen '{screen_title}', then press Return to begin its captures… ")
                for posture_slug, posture_title in POSTURES:
                    for orientation_slug, orientation_title in orientations:
                        input(
                            f"Set Device Hub to {posture_title.lower()} and {orientation_title.lower()}, "
                            f"with '{screen_title}' visible; press Return… "
                        )
                        capture: dict[str, str] = {
                            "screen": screen_slug,
                            "screenTitle": screen_title,
                            "posture": posture_slug,
                            "postureTitle": posture_title,
                            "orientation": orientation_slug,
                            "orientationTitle": orientation_title,
                        }
                        for appearance in APPEARANCES:
                            run(["xcrun", "simctl", "ui", args.device_id, "appearance", appearance])
                            time.sleep(1)
                            filename = f"{screen_slug}--{posture_slug}--{orientation_slug}--{appearance}.png"
                            relative_path = Path("captures") / filename
                            display = displays["outer" if posture_slug == "closed-outer" else "inner"]
                            run(["xcrun", "simctl", "io", args.device_id, "screenshot",
                                 f"--display={display}", str(staging_dir / relative_path)])
                            capture[appearance] = relative_path.as_posix()
                        captures.append(capture)

            ready_at = dt.datetime.now(dt.timezone.utc)
            elapsed = int((ready_at - pushed_at).total_seconds())
            if elapsed < -5:
                raise CaptureError("The supplied push time is more than five seconds in the future.")
            if original_appearance in APPEARANCES:
                run(["xcrun", "simctl", "ui", args.device_id, "appearance", original_appearance])
            page_html = build_html(args.page_title, revision, pushed_at, ready_at,
                                   simulator_name, screens, captures)
            (staging_dir / "index.html").write_text(page_html, encoding="utf-8")
            metadata = {
                "pageTitle": args.page_title,
                "sourceRevision": revision,
                "simulator": simulator_name,
                "pushedAt": pushed_at.isoformat().replace("+00:00", "Z"),
                "pageReadyAt": ready_at.isoformat().replace("+00:00", "Z"),
                "changeToPageSeconds": max(0, elapsed),
                "screens": [{"slug": slug, "title": title} for slug, title in screens],
                "captures": captures,
            }
            (staging_dir / "metadata.json").write_text(
                json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            staging_dir.rename(page_dir)
        finally:
            if original_appearance in APPEARANCES:
                subprocess.run(["xcrun", "simctl", "ui", args.device_id,
                                "appearance", original_appearance], check=False)
            if staging_dir.exists():
                shutil.rmtree(staging_dir)

        print(f"Page ready: {page_dir / 'index.html'}")
        print(f"Change-to-page time: {format_duration(max(0, elapsed))}")
        return 0
    except (CaptureError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"capture-preview-page: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("capture-preview-page: cancelled", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
