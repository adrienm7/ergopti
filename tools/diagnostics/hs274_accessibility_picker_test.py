# tools/diagnostics/hs274_accessibility_picker_test.py
"""Verify bundle ownership inputs and native file-picker receipt handling."""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from hs274_accessibility_picker import select_application


class PickerTests(unittest.TestCase):
    def test_invalid_bundle_does_not_start_ui(self):
        with TemporaryDirectory() as root, patch("hs274_accessibility_picker.subprocess.run") as run:
            with self.assertRaises(ValueError):
                select_application(root, {})
            run.assert_not_called()

    def test_path_is_data_and_selection_requires_exact_native_receipt(self):
        with TemporaryDirectory(prefix="hs274 picker ") as root:
            app = Path(root) / "Hammerspoon.app"
            executable = app / "Contents/MacOS/Hammerspoon"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            for code, receipt in ((0, "application_selected\n"), (1, "application_selected"), (0, "picker_open")):
                report = {}
                with self.subTest(code=code, receipt=receipt), patch.dict("os.environ", {"RUNNER_TEMP": root}), patch(
                        "hs274_accessibility_picker.subprocess.run",
                        return_value=SimpleNamespace(returncode=code, stdout=receipt, stderr="native detail")) as run:
                    if code == 0 and receipt.strip() == "application_selected":
                        select_application(app, report)
                    else:
                        with self.assertRaises(RuntimeError):
                            select_application(app, report)
                    command = run.call_args.args[0]
                    self.assertEqual(command[-3], str(app.resolve()))
                    self.assertNotIn(str(app.resolve()), command[-4])
                    self.assertEqual(command[-2], str(Path(root) / "hs274-picker-before-open.png"))
                    self.assertEqual(command[-1], str(Path(root) / "hs274-picker-after-open.png"))
                    self.assertEqual(report["hammerspoon_accessibility_picker"]["stderr"], "native detail")


if __name__ == "__main__":
    unittest.main()
