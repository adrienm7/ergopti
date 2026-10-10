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
    def test_actual_ownership_pin_accepts_current_source_and_refuses_changed_bytes(self):
        path = Path(__file__).resolve().parents[1] / "macos_owned_process.py"
        raw = path.read_bytes()
        with mock.patch("subprocess.Popen", side_effect=AssertionError("native child forbidden")):
            ownership = subject.pinned_module(path, "ownership")
        self.assertTrue(callable(ownership.acquire_owned))
        self.assertTrue(callable(ownership.NativeProcessGroups))
        with mock.patch.object(Path, "read_bytes", return_value=raw + b"\nforeign = True\n"):
            with self.assertRaisesRegex(RuntimeError, "Native dependency source pin differs"):
                subject.pinned_module(path, "ownership")

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


class MetadataEntryControls(unittest.TestCase):
    def test_token_is_consumed_before_non_native_refusal_and_module_loading(self):
        import os
        import contextlib
        import io

        with (
            mock.patch.dict(os.environ, {"ERGOPTI_NATIVE_HS_METADATA_TOKEN": "ghs_PRIVATE"}),
            mock.patch.object(subject.sys, "platform", "linux"),
            mock.patch.object(subject, "pinned_module") as loading,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(
                subject.main(
                    [
                        "--owner-library",
                        "owner",
                        "--inventory-library",
                        "inventory",
                        "--scratch",
                        ".",
                        "--download",
                    ]
                ),
                77,
            )
            self.assertNotIn("ERGOPTI_NATIVE_HS_METADATA_TOKEN", os.environ)
        loading.assert_not_called()

    def test_anonymous_non_native_refusal_does_not_allocate_modules(self):
        import os
        import contextlib
        import io

        with (
            mock.patch.dict(os.environ),
            mock.patch.object(subject.sys, "platform", "linux"),
            mock.patch.object(subject, "pinned_module") as loading,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            os.environ.pop("ERGOPTI_NATIVE_HS_METADATA_TOKEN", None)
            self.assertEqual(
                subject.main(
                    [
                        "--owner-library",
                        "owner",
                        "--inventory-library",
                        "inventory",
                        "--scratch",
                        ".",
                        "--download",
                    ]
                ),
                77,
            )
        loading.assert_not_called()


class NativeEntryTokenBoundary(unittest.TestCase):
    def inventory(self):
        path = Path(__file__).resolve().parents[1] / "native_hs_program_providers/run_native.py"
        return subject.pinned_module(path, "inventory")

    def test_valid_token_is_absent_before_actual_native_constructor(self):
        import os
        import contextlib
        import io
        from types import SimpleNamespace

        inventory = self.inventory()
        error = RuntimeError("CONTROLLED_CONSTRUCTOR_BOUNDARY")

        def construct():
            self.assertNotIn("ERGOPTI_NATIVE_HS_METADATA_TOKEN", os.environ)
            raise error

        owner = SimpleNamespace(NativeProcessGroups=construct)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scratch = root / "scope"
            scratch.mkdir(mode=0o700)
            arguments = [
                "--scratch",
                str(scratch),
                "--owner-library",
                "owner",
                "--inventory-library",
                "inventory",
                "--download",
            ]
            with (
                mock.patch.dict(os.environ, {"ERGOPTI_NATIVE_HS_METADATA_TOKEN": "ghs_PRIVATE"}),
                mock.patch.object(subject.sys, "platform", "darwin"),
                mock.patch.object(subject.sys, "version_info", (3, 13)),
                mock.patch.object(
                    subject,
                    "pinned_module",
                    side_effect=lambda path, kind: owner if kind == "ownership" else inventory,
                ),
                mock.patch.object(inventory, "source_hashes") as git,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(subject.main(arguments), 77)
            git.assert_not_called()

    def test_malformed_token_refuses_before_actual_native_constructor(self):
        import os
        import contextlib
        import io
        from types import SimpleNamespace

        inventory = self.inventory()
        construction = mock.Mock(side_effect=AssertionError("allocation forbidden"))
        owner = SimpleNamespace(NativeProcessGroups=construction)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scratch = root / "scope"
            scratch.mkdir(mode=0o700)
            arguments = [
                "--scratch",
                str(scratch),
                "--owner-library",
                "owner",
                "--inventory-library",
                "inventory",
                "--download",
            ]
            with (
                mock.patch.dict(os.environ, {"ERGOPTI_NATIVE_HS_METADATA_TOKEN": "PRIVATE\nTOKEN"}),
                mock.patch.object(subject.sys, "platform", "darwin"),
                mock.patch.object(subject.sys, "version_info", (3, 13)),
                mock.patch.object(
                    subject,
                    "pinned_module",
                    side_effect=lambda path, kind: owner if kind == "ownership" else inventory,
                ),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaisesRegex(ValueError, "^metadata_token_refused$"):
                    subject.main(arguments)
                self.assertNotIn("ERGOPTI_NATIVE_HS_METADATA_TOKEN", os.environ)
        construction.assert_not_called()


if __name__ == "__main__":
    unittest.main()
