# tools/diagnostics/hs274_target_test.py
"""Exercise external target ownership without requiring Cocoa on Windows."""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from hs274_target import owned_target


class TargetTests(unittest.TestCase):
    def test_exact_target_is_cleaned_after_success_and_primary_failure(self):
        for rejected in (False, True, "cleanup"):
            with self.subTest(rejected=rejected), TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                executable = root / "target"
                executable.write_bytes(b"fixture")
                process = SimpleNamespace(pid=42, returncode=-15)
                native = SimpleNamespace(matching=lambda _: [])
                cleaned, report = [], {}

                def cleanup(actual, path, child):
                    self.assertIs(actual, native)
                    self.assertEqual(path, executable)
                    self.assertIs(child, process)
                    cleaned.append(True)
                    if rejected:
                        raise RuntimeError("cleanup failed")

                lifecycle = SimpleNamespace(NativeProcesses=lambda: native, cleanup=cleanup)
                with patch.dict("os.environ", {"HS274_CONTEXT_TARGET": str(executable)}), \
                        patch("hs274_target.subprocess.Popen", return_value=process) as launch:
                    if rejected is True:
                        with self.assertRaisesRegex(ValueError, "consumer failed"):
                            with owned_target(root, report, lifecycle):
                                raise ValueError("consumer failed")
                        self.assertFalse(report["context_target"]["settled"])
                        self.assertIn("cleanup failed", report["context_target"]["cleanup_error"])
                    elif rejected == "cleanup":
                        with self.assertRaisesRegex(RuntimeError, "cleanup failed"):
                            with owned_target(root, report, lifecycle):
                                pass
                    else:
                        with owned_target(root, report, lifecycle) as config:
                            self.assertEqual(config["target_pid"], 42)
                            self.assertEqual(cleaned, [])
                        self.assertTrue(report["context_target"]["settled"])
                    self.assertEqual(cleaned, [True])
                    self.assertEqual(launch.call_args.args[0][0], str(executable))

    def test_existing_target_owner_prevents_launch(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            executable = root / "target"
            executable.write_bytes(b"fixture")
            lifecycle = SimpleNamespace(NativeProcesses=lambda: SimpleNamespace(matching=lambda _: [41]))
            with patch.dict("os.environ", {"HS274_CONTEXT_TARGET": str(executable)}), \
                    patch("hs274_target.subprocess.Popen") as launch:
                with self.assertRaisesRegex(RuntimeError, "already has an owner"):
                    with owned_target(root, {}, lifecycle):
                        self.fail("Foreign target admitted")
                launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
