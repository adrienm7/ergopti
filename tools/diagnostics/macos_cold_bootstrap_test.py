"""Independent receiving rejection cases; these do not emulate native macOS."""

import copy
import tempfile
from pathlib import Path
import unittest
from unittest import mock
from subprocess import CompletedProcess

import macos_cold_bootstrap as cold

from macos_cold_bootstrap import PREFIX, REPOSITORY, SOURCE_PATHS, digest, validate


class ColdReceiptTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        driver = Path(self.root.name) / "driver"
        source = driver / "modules/llm/ensure-mlx-deps.sh"
        source.parent.mkdir(parents=True)
        source.write_text("independent source bytes\n")
        self.config = {
            "driver": str(driver),
            "denied_runtime_paths": ["/usr/bin/python3"],
        }
        self.result = {
            "success": True,
            "state": "ready",
            "runtime_installed": True,
            "runtime": "native Hammerspoon",
            "tasks": 1,
            "absent_python_selected": True,
            "python_resolver": "unmodified production resolver",
            "python_state": "python_missing",
            "native_python_candidates_count": 0,
            "denied_runtime_paths": ["/usr/bin/python3"],
            "receipt_retired": True,
            "receipt_removed": True,
            "worker_status": 0,
            "nonce": "independent-nonce",
            "source_sha256": digest(source),
            "native_cli": ["--managed-pty-worker", "1800000"],
            "worker_pid": 123,
            "receipt_path": str(Path(self.root.name) / "removed-receipt"),
            "physical_receipt": {
                "version": 1,
                "nonce": "independent-nonce",
                "state": "retired",
                "group_retired": True,
                "guardian_reaped": True,
                "pty_eof": True,
                "handles_closed": True,
                "status_valid": True,
                "exit_status": 0,
                "worker_status": 0,
                "source_admitted": True,
            },
        }

    def test_real_source_inventory_contains_the_loadable_shared_receipt(self):
        self.assertIn("_shared/lua/core/llm/native_pty_receipt.lua", SOURCE_PATHS)
        self.assertNotIn("_shared/core/llm/native_pty_receipt.lua", SOURCE_PATHS)
        for relative in SOURCE_PATHS:
            with self.subTest(source=relative):
                self.assertTrue((REPOSITORY / PREFIX / relative).is_file())

    def test_independently_authored_complete_receipt(self):
        validate(self.result, self.config)

    def test_every_physical_closure_fence_required(self):
        for name in (
            "group_retired",
            "guardian_reaped",
            "pty_eof",
            "handles_closed",
            "status_valid",
            "source_admitted",
        ):
            for value in (False, None, 1, "true"):
                with self.subTest(name=name, value=value):
                    changed = copy.deepcopy(self.result)
                    changed["physical_receipt"][name] = value
                    with self.assertRaises(RuntimeError):
                        validate(changed, self.config)

    def test_source_callback_cli_and_receipt_retirement_are_independent(self):
        for name, value in (
            ("source_sha256", "0" * 64),
            ("worker_status", False),
            ("worker_status", 74),
            ("tasks", True),
            ("nonce", "foreign"),
            ("native_cli", ["--managed-pty-worker", "600000"]),
            ("receipt_retired", False),
            ("receipt_removed", False),
            ("python_resolver", "fake missing Python adapter"),
            ("python_state", "ready"),
            ("native_python_candidates_count", True),
            ("native_python_candidates_count", 1),
            ("denied_runtime_paths", []),
        ):
            with self.subTest(name=name):
                changed = copy.deepcopy(self.result)
                changed[name] = value
                with self.assertRaises(RuntimeError):
                    validate(changed, self.config)
        path = Path(self.result["receipt_path"])
        path.touch()
        with self.assertRaises(RuntimeError):
            validate(self.result, self.config)


class ColdIsolationBoundaryTests(unittest.TestCase):
    """Portable literal/refusal checks; mocks do not qualify native isolation."""

    def test_literal_profile_has_only_scoped_runtime_read_and_exec_denials(self):
        self.assertEqual(
            cold.sandbox_profile(["/usr/bin/python3", "/opt/homebrew/bin/uv"]),
            "(version 1)\n(allow default)\n(deny file-read* process-exec\n"
            '  (literal "/usr/bin/python3")\n'
            '  (literal "/opt/homebrew/bin/uv")\n)\n',
        )
        lua = Path(cold.__file__).with_suffix(".lua").read_text()
        self.assertIn("local selected, state = python.resolve()", lua)
        self.assertIn("#python.native_candidates()", lua)
        self.assertNotIn("python.resolve =", lua)
        self.assertNotIn("python.native_candidates =", lua)
        self.assertNotIn("python._set_deps", lua)

    def test_mocked_probe_boundary_requires_allowed_before_and_denied_inside(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "stock-runtime"
            file.write_bytes(b"independent runtime identity bytes")
            profile = Path(directory) / "cold-runtime.sb"
            paths = [str(file)]
            calls = []

            def probe(argv, **_kwargs):
                calls.append(argv)
                denied = argv[0] == "/usr/bin/sandbox-exec"
                return CompletedProcess(
                    argv,
                    126 if denied else 0,
                    stdout="",
                    stderr="Operation not permitted" if denied else "",
                )

            with mock.patch.object(cold.subprocess, "run", side_effect=probe):
                received = cold.qualify_runtime_isolation(paths, profile)
            actual = file.stat()
            self.assertEqual(
                received,
                [
                    {
                        "path": str(file),
                        "sha256": digest(file),
                        "device": actual.st_dev,
                        "inode": actual.st_ino,
                        "bytes": len(b"independent runtime identity bytes"),
                        "read_denied": True,
                        "native": True,
                        "exec_denied": True,
                    }
                ],
            )
            self.assertEqual(
                calls,
                [
                    [
                        "/usr/bin/sandbox-exec",
                        "-f",
                        str(profile),
                        "/bin/cat",
                        str(file),
                    ],
                    ["/usr/bin/lipo", "-verify_arch", "arm64", str(file)],
                    [str(file), "--version"],
                    [
                        "/usr/bin/sandbox-exec",
                        "-f",
                        str(profile),
                        str(file),
                        "--version",
                    ],
                ],
            )

    def test_mocked_kernel_probe_refuses_allowed_read_exec_and_missing_native_proof(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "stock-runtime"
            file.write_bytes(b"independent runtime identity bytes")
            for refusal in (
                "read_allowed",
                "exec_allowed",
                "wrong_error",
                "no_native",
                "changed_bytes",
            ):
                file.write_bytes(b"independent runtime identity bytes")
                with self.subTest(refusal=refusal):

                    def probe(argv, **_kwargs):
                        denied = argv[0] == "/usr/bin/sandbox-exec"
                        read = "/bin/cat" in argv
                        native = argv[0] == "/usr/bin/lipo"
                        code = 126 if denied else 0
                        if (read and refusal == "read_allowed") or (
                            denied and not read and refusal == "exec_allowed"
                        ):
                            code = 0
                        if native and refusal == "no_native":
                            code = 1
                        if denied and not read and refusal == "changed_bytes":
                            file.write_bytes(b"changed independent bytes")
                        error = (
                            "No such file"
                            if refusal == "wrong_error"
                            else "Operation not permitted"
                        )
                        return CompletedProcess(
                            argv, code, stdout="", stderr=error if denied else ""
                        )

                    with mock.patch.object(cold.subprocess, "run", side_effect=probe):
                        with self.assertRaises(RuntimeError):
                            cold.qualify_runtime_isolation([str(file)], Path(directory) / "profile")


if __name__ == "__main__":
    unittest.main()
