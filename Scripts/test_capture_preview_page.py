"""Focused behavior checks for the preview-page capture helper."""

from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import zlib
import unittest
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("capture-preview-page.py")
SPEC = importlib.util.spec_from_file_location("capture_preview_page", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load capture-preview-page.py for focused checks.")
capture_page = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = capture_page
SPEC.loader.exec_module(capture_page)


def run_main_with_unavailable_capture(
    page_dir: Path, arguments: tuple[str, ...], partial: bool = False,
    landscape_not_declared: bool = False,
) -> tuple[int, str, str]:
    stdout = io.StringIO()
    stderr = io.StringIO()
    test_record = {
        "appearance": "light",
        "wrapperExitCode": 0,
        "wrapperError": None,
        "result": "passed",
        "passedTests": 1,
        "failedTests": 0,
        "testPassed": True,
        "resultBundle": None,
        "attachmentExportExitCode": 0,
        "manifestAvailable": True,
    }

    def attempt(command: list[str], **_kwargs: object) -> dict:
        if command[:2] == ["git", "rev-parse"]:
            return {"returnCode": 0, "output": "test-revision", "error": None}
        if command[:4] == ["xcrun", "simctl", "ui", "SIM-1"] and command[-1] == "appearance":
            return {"returnCode": 0, "output": "solarized", "error": None}
        return {"returnCode": 0, "output": "", "error": None}

    def capture_available(*args: object) -> dict:
        slug, screen_title, _attachment_name, orientation, appearance = args[:5]
        has_partial_capture = partial and slug == "inbox" and orientation == "portrait" and appearance == "light"
        has_landscape_capture = landscape_not_declared and slug == "inbox" and orientation == "landscape" and appearance == "light"
        if has_partial_capture or has_landscape_capture:
            return {
                "screen": slug,
                "screenTitle": screen_title,
                "requestedOrientation": orientation,
                "appearance": appearance,
                "status": "captured",
                "file": f"captures/{slug}-{orientation}-{appearance}.png",
                "verification": "verified",
                "orientation": orientation,
                "orientationVerified": True,
                "width": 844 if orientation == "landscape" else 390,
                "height": 390 if orientation == "landscape" else 844,
                "reasons": [],
                "captureTimestampUTC": None,
            }
        return capture_page.missing_capture(
            slug, screen_title, orientation, appearance, "No screenshot was captured.",
        )

    def run_capture_test(_device_id: str, appearance: str, _export_dir: Path,
                         _warnings: list[str]) -> tuple[dict, list[dict]]:
        record = test_record.copy()
        record["appearance"] = appearance
        return record, []

    argv = [
        "capture-preview-page.py",
        "--device-id", "SIM-1",
        "--page-dir", str(page_dir),
        *arguments,
    ]
    patches = [
        mock.patch.object(capture_page.sys, "argv", argv),
        mock.patch.object(capture_page, "find_simulator", return_value="Test Simulator"),
        mock.patch.object(capture_page, "attempt", side_effect=attempt),
        mock.patch.object(capture_page, "run_capture_test", side_effect=run_capture_test),
        mock.patch.object(capture_page, "read_orientation_support", return_value=(
            {"portrait": "declared", "landscape": "not declared" if landscape_not_declared else "declared"},
            ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft"],
        )),
        mock.patch.object(capture_page, "capture_available_image", side_effect=capture_available),
        mock.patch("sys.stdout", stdout),
        mock.patch("sys.stderr", stderr),
    ]
    with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7]:
        result = capture_page.main()
    return result, stdout.getvalue(), stderr.getvalue()


class PreviewPageImageOrientationTests(unittest.TestCase):
    def test_exif_rotated_simulator_png_is_verified_in_display_orientation(self) -> None:
        width, height, orientation = 1206, 2622, 8
        ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
        exif = (
            b"II*\x00" + struct.pack("<I", 8) + struct.pack("<H", 1)
            + struct.pack("<HHIHH", 0x0112, 3, 1, orientation, 0)
            + struct.pack("<I", 0)
        )

        def chunk(kind: bytes, payload: bytes) -> bytes:
            body = kind + payload
            return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

        png = capture_page.PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"eXIf", exif) + chunk(b"IEND", b"")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            export_dir = root / "export"
            captures_dir = root / "captures"
            export_dir.mkdir()
            captures_dir.mkdir()
            (export_dir / "landscape.png").write_bytes(png)
            attachment = {
                "exportedFileName": "landscape.png",
                "timestamp": 1793012400,
                "suggestedHumanReadableName": "preview-landscape-inbox_1.png",
                "deviceId": "SIM-1",
                "deviceName": "Test Simulator",
            }
            warnings: list[str] = []

            capture = capture_page.capture_available_image(
                "inbox", "Inbox", "preview-landscape-inbox", "landscape", "light",
                [attachment], export_dir, captures_dir, True,
                {"testPassed": True}, warnings,
            )

            self.assertEqual(capture["verification"], "verified")
            self.assertEqual(capture["orientation"], "landscape")
            self.assertTrue(capture["orientationVerified"])
            self.assertEqual((capture["width"], capture["height"]), (2622, 1206))
            self.assertEqual((capture["pixelWidth"], capture["pixelHeight"]), (1206, 2622))
            self.assertEqual(capture["embeddedOrientation"], 8)
            self.assertEqual(warnings, [])


class PreviewPageInputTests(unittest.TestCase):
    def test_missing_and_malformed_push_times_still_write_a_page(self) -> None:
        cases = (
            ((), "No --pushed-at value was provided"),
            (("--pushed-at", "not-a-timestamp"), "could not be parsed as ISO 8601"),
        )
        for index, (arguments, expected_note) in enumerate(cases):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as temporary_directory:
                page_dir = Path(temporary_directory) / f"page-{index}"
                result, stdout, stderr = run_main_with_unavailable_capture(page_dir, arguments)

                self.assertEqual(result, 0, stderr)
                page = (page_dir / "index.html").read_text(encoding="utf-8")
                metadata = json.loads(
                    (page_dir / "metadata.json").read_text(encoding="utf-8"),
                )
                self.assertIn("pushed unknown", page)
                self.assertIn("Change-to-page time unavailable", page)
                self.assertIn(expected_note, page)
                self.assertIn("Page ready (unavailable)", stdout)
                self.assertIsNone(metadata["changeToPageSeconds"])
                self.assertTrue(metadata["timingStatus"].startswith("unavailable-"))

    def test_blank_title_falls_back_and_the_cli_still_writes_a_page(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            page_dir = Path(temporary_directory) / "page"
            result, _stdout, stderr = run_main_with_unavailable_capture(
                page_dir, ("--page-title", "   "),
            )

            self.assertEqual(result, 0, stderr)
            page = (page_dir / "index.html").read_text(encoding="utf-8")
            self.assertIn("<h1>Harklight preview</h1>", page)
            self.assertIn("No page title was provided", page)

    def test_timezone_free_push_time_is_treated_as_local_and_noted(self) -> None:
        warnings: list[str] = []
        pushed_at, interpretation = capture_page.parse_timestamp(
            "2026-10-26T11:00:00", warnings,
        )

        self.assertEqual(interpretation, "assumed-local")
        self.assertIsNotNone(pushed_at)
        self.assertTrue(any("interpreting it as local time" in item for item in warnings))

    def test_partial_capture_runs_through_cli_and_keeps_available_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            page_dir = Path(temporary_directory) / "page"
            result, stdout, stderr = run_main_with_unavailable_capture(
                page_dir, ("--pushed-at", "2026-10-26T11:00:00Z"), partial=True,
            )

            self.assertEqual(result, 0, stderr)
            page = (page_dir / "index.html").read_text(encoding="utf-8")
            metadata = json.loads(
                (page_dir / "metadata.json").read_text(encoding="utf-8"),
            )
            self.assertIn('src="captures/inbox-portrait-light.png"', page)
            self.assertIn("1 of 8 images available", page)
            self.assertIn("Requested orientation: portrait", page)
            self.assertIn("Requested orientation: landscape", page)
            self.assertEqual(page.count('id="appearance-switch"'), 1)
            self.assertEqual(metadata["requestedOrientations"], ["portrait", "landscape"])
            self.assertEqual(len(metadata["captureMatrix"]), 8)
            self.assertIn("Dark capture unavailable.", page)
            self.assertIn("Page ready (partial)", stdout)
            self.assertEqual(metadata["pageStatus"], "partial")
            self.assertEqual(metadata["imageCount"], 1)

    def test_landscape_without_declared_support_still_builds_an_unverified_page(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            page_dir = Path(temporary_directory) / "page"
            result, _stdout, stderr = run_main_with_unavailable_capture(
                page_dir, ("--pushed-at", "2026-10-26T11:00:00Z"),
                landscape_not_declared=True,
            )

            self.assertEqual(result, 0, stderr)
            page = (page_dir / "index.html").read_text(encoding="utf-8")
            metadata = json.loads((page_dir / "metadata.json").read_text(encoding="utf-8"))
            landscape = next(
                item for item in metadata["captureMatrix"]
                if item["requestedOrientation"] == "landscape"
                and item["appearance"] == "light"
                and item["status"] == "captured"
            )
            self.assertIn('src="captures/inbox-landscape-light.png"', page)
            self.assertIn("Built-app orientation support: portrait declared, landscape not declared", page)
            self.assertEqual(landscape["verification"], "unverified")
            self.assertEqual(metadata["pageStatus"], "partial")

    def test_landscape_capture_is_saved_in_its_requested_slot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            export_dir = root / "export"
            captures_dir = root / "captures"
            export_dir.mkdir()
            captures_dir.mkdir()
            exported_name = "landscape.png"
            png = capture_page.PNG_SIGNATURE + b"\x00" * 8 + struct.pack(">II", 844, 390)
            (export_dir / exported_name).write_bytes(png)
            warnings: list[str] = []
            attachment = {
                "exportedFileName": exported_name,
                "timestamp": 1793012400,
                "suggestedHumanReadableName": "preview-landscape-inbox_1.png",
                "deviceId": "SIM-1",
                "deviceName": "Test Simulator",
            }
            record = {"testPassed": True}

            capture = capture_page.capture_available_image(
                "inbox", "Inbox", "preview-landscape-inbox",
                "landscape", "dark", [attachment], export_dir, captures_dir,
                True, record, warnings,
            )

            self.assertEqual(capture["status"], "captured")
            self.assertEqual(capture["requestedOrientation"], "landscape")
            self.assertTrue(capture["orientationVerified"])
            self.assertEqual(capture["file"], "captures/inbox-landscape-dark.png")
            self.assertEqual((capture["width"], capture["height"]), (844, 390))
            self.assertTrue((captures_dir / "inbox-landscape-dark.png").is_file())
            self.assertEqual(capture["verification"], "verified")

    def test_default_output_is_timestamped_in_current_directory(self) -> None:
        output_path, defaulted = capture_page.requested_output_directory(None)

        self.assertTrue(defaulted)
        self.assertEqual(output_path.parent, Path.cwd())
        self.assertRegex(output_path.name, r"^harklight-preview-\d{8}T\d{6}Z$")

    def test_existing_output_folder_is_preserved_by_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            requested = Path(temporary_directory) / "preview"
            requested.mkdir()
            marker = requested / "keep.txt"
            marker.write_text("original", encoding="utf-8")

            result, stdout, stderr = run_main_with_unavailable_capture(requested, ())

            self.assertEqual(result, 0, stderr)
            sibling = requested.with_name("preview-1")
            self.assertTrue(marker.is_file())
            self.assertEqual(marker.read_text(encoding="utf-8"), "original")
            self.assertTrue((sibling / "index.html").is_file())
            self.assertIn("page written to sibling", stdout)

    def test_missing_simulator_selection_explains_how_to_set_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            page_dir = Path(temporary_directory) / "page"
            stderr = io.StringIO()
            argv = ["capture-preview-page.py", "--page-dir", str(page_dir)]
            with (
                mock.patch.object(capture_page.sys, "argv", argv),
                mock.patch.dict(capture_page.os.environ, {"HARKLIGHT_SIMULATOR_ID": ""}),
                mock.patch("sys.stderr", stderr),
            ):
                result = capture_page.main()

            self.assertEqual(result, 2)
            self.assertIn("Set HARKLIGHT_SIMULATOR_ID or pass --device-id", stderr.getvalue())
            self.assertFalse(page_dir.exists())

    def test_unbooted_simulator_explains_how_to_boot_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            page_dir = Path(temporary_directory) / "page"
            stderr = io.StringIO()
            argv = [
                "capture-preview-page.py", "--device-id", "SIM-1",
                "--page-dir", str(page_dir),
            ]
            device_list = json.dumps({
                "devices": {
                    "runtime": [{"udid": "SIM-1", "name": "Test Simulator", "state": "Shutdown"}],
                },
            })
            with (
                mock.patch.object(capture_page.sys, "argv", argv),
                mock.patch.object(capture_page, "run", return_value=device_list),
                mock.patch("sys.stderr", stderr),
            ):
                result = capture_page.main()

            self.assertEqual(result, 2)
            self.assertIn("is not booted", stderr.getvalue())
            self.assertIn("xcrun simctl boot SIM-1", stderr.getvalue())
            self.assertFalse(page_dir.exists())


if __name__ == "__main__":
    unittest.main()
