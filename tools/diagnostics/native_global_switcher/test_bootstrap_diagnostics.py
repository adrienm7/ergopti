# tools/diagnostics/native_global_switcher/test_bootstrap_diagnostics.py
"""Actual pinned bootstrap routing only; no native macOS children are allocated."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
from urllib.error import HTTPError

import run_native_probe as subject


class BootstrapCallerControls(unittest.TestCase):
    def inventory(self):
        path = Path(__file__).resolve().parents[1] / "native_hs_program_providers/run_native.py"
        raw = path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), subject.DEPENDENCIES["inventory"])
        inventory = subject.pinned_module(path, "inventory")
        self.assertTrue(callable(inventory.bootstrap_response))
        return inventory

    def test_inventory_pin_rejects_foreign_source_before_execution(self):
        path = Path(__file__).resolve().parents[1] / "native_hs_program_providers/run_native.py"
        self.inventory()
        with mock.patch.object(
            Path, "read_bytes", return_value=b"raise AssertionError('foreign code executed')\n"
        ):
            with self.assertRaises(RuntimeError):
                subject.pinned_module(path, "inventory")

    def test_actual_metadata_and_archive_failures_remain_unqualified_and_physically_empty(self):
        for phase in ("release_metadata", "archive_download"):
            with self.subTest(phase=phase):
                inventory = self.inventory()
                allocation = mock.Mock(
                    side_effect=AssertionError("native acquisition forbidden in portable control")
                )
                ownership = SimpleNamespace(
                    NativeProcessGroups=lambda: object(), acquire_owned=allocation
                )
                error = HTTPError(
                    "PRIVATE_URL", 403, "PRIVATE_MESSAGE", {"PRIVATE_HEADER": "PRIVATE_BODY"}, None
                )
                logged = io.StringIO()
                with tempfile.TemporaryDirectory() as directory:
                    scratch = Path(directory) / "scope"
                    scratch.mkdir(mode=0o700)
                    with contextlib.ExitStack() as stack:
                        stack.enter_context(mock.patch.object(subject.sys, "platform", "darwin"))
                        stack.enter_context(
                            mock.patch.object(
                                subject,
                                "pinned_module",
                                side_effect=lambda _path, kind: (
                                    ownership if kind == "ownership" else inventory
                                ),
                            )
                        )
                        stack.enter_context(
                            mock.patch.object(inventory, "urlopen", side_effect=error)
                        )
                        stack.enter_context(
                            mock.patch.object(subject, "urlopen", side_effect=error, create=True)
                        )
                        if phase == "archive_download":
                            stack.enter_context(
                                mock.patch.object(
                                    inventory,
                                    "trusted_asset",
                                    return_value={
                                        "browser_download_url": "PRIVATE_URL",
                                        "size": 1024,
                                    },
                                )
                            )
                        stack.enter_context(contextlib.redirect_stdout(logged))
                        status = subject.main(
                            [
                                "--scratch",
                                str(scratch),
                                "--owner-library",
                                str(Path(__file__).resolve().parents[1] / "macos_owned_process.py"),
                                "--inventory-library",
                                str(
                                    Path(__file__).resolve().parents[1]
                                    / "native_hs_program_providers/run_native.py"
                                ),
                                "--download",
                            ]
                        )
                    report = json.loads((scratch / "report.json").read_text())
                self.assertEqual(status, 1)
                self.assertEqual(report["error_category"], "HTTPError")
                self.assertFalse(report["native_switcher_qualified"])
                self.assertEqual(report["native_child_capabilities"], [])
                self.assertIsNone(report["native_receipt"])
                allocation.assert_not_called()
                lines = [json.loads(line) for line in logged.getvalue().splitlines()]
                self.assertEqual(
                    lines[0],
                    {
                        "schema": 1,
                        "contract": "macos-native-bootstrap-failure",
                        "phase": phase,
                        "family": "http_error",
                        "http_status": 403,
                        "native_pass": False,
                    },
                )
                self.assertFalse(lines[-1]["native_switcher_qualified"])
                for secret in ("PRIVATE_URL", "PRIVATE_MESSAGE", "PRIVATE_HEADER", "PRIVATE_BODY"):
                    self.assertNotIn(secret, logged.getvalue())


if __name__ == "__main__":
    unittest.main()
