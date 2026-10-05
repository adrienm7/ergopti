# tools/diagnostics/native_global_switcher/test_ci_entry.py
"""Closed controller delegation controls; no download or native launch occurs."""

import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_ci_probe


class CIEntry(unittest.TestCase):
    def invoke(self, status, source_alias=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            if source_alias:
                alias = root / "source-alias"
                alias.symlink_to(root, target_is_directory=True)
                root = alias
            output = root / "own-new-probe"
            canonical_root = root.resolve(strict=True)
            capture = io.StringIO()
            with patch.object(
                run_ci_probe.run_native_probe, "main", return_value=status
            ) as controller:
                with contextlib.redirect_stdout(capture):
                    result = run_ci_probe.main(
                        ["--source-root", str(root), "--output", str(output)]
                    )
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                controller.call_args.args,
                (
                    [
                        "--download",
                        "--scratch",
                        str(output),
                        "--owner-library",
                        str(canonical_root / "tools/diagnostics/macos_owned_process.py"),
                        "--inventory-library",
                        str(
                            canonical_root
                            / "tools/diagnostics/native_hs_program_providers/run_native.py"
                        ),
                    ],
                ),
            )
            self.assertEqual(controller.call_count, 1)
            return result, capture.getvalue()

    def test_prerequisite_refusal_and_unknown_failure_are_ci_failure(self):
        for status in (77, 1, None, False):
            # False must not silently equal successful zero; the controller's
            # actual return is a closed integer, but wrapper boundary stays strict.
            result, text = self.invoke(status)
            self.assertEqual(result, 1)
            self.assertIn("::error", text)
            self.assertNotIn("::notice", text)

    def test_exact_zero_reports_isolated_native_scope_only(self):
        result, text = self.invoke(0)
        self.assertEqual(result, 0)
        self.assertIn("product/physical-key qualification remains unexecuted", text)
        self.assertNotIn("::error", text)

    def test_source_alias_uses_canonical_libraries_and_literal_owned_output(self):
        result, text = self.invoke(1, source_alias=True)
        self.assertEqual(result, 1)
        self.assertIn("::error", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
