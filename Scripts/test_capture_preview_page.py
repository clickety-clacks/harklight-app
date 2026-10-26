"""Focused behavior checks for the preview-page capture helper."""

from __future__ import annotations

import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
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
        slug, screen_title, _attachment_name, appearance = args[:4]
        if partial and slug == "inbox" and appearance == "light":
            return {
                "status": "captured",
                "file": "captures/inbox-portrait-light.png",
                "verification": "unverified",
                "orientation": "portrait",
                "width": 390,
                "height": 844,
                "reasons": ["Synthetic focused check capture."],
                "captureTimestampUTC": None,
            }
        return capture_page.missing_capture(
            slug, screen_title, appearance, "No screenshot was captured.",
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
        mock.patch.object(capture_page, "read_portrait_support", return_value=("declared", ["portrait"])),
        mock.patch.object(capture_page, "capture_available_image", side_effect=capture_available),
        mock.patch("sys.stdout", stdout),
        mock.patch("sys.stderr", stderr),
    ]
    with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7]:
        result = capture_page.main()
    return result, stdout.getvalue(), stderr.getvalue()


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
            self.assertIn("1 of 4 images available", page)
            self.assertIn("Dark capture unavailable.", page)
            self.assertIn("Page ready (partial)", stdout)
            self.assertEqual(metadata["pageStatus"], "partial")
            self.assertEqual(metadata["imageCount"], 1)

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
