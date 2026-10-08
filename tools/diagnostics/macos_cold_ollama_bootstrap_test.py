# tools/diagnostics/macos_cold_ollama_bootstrap_test.py
"""Independent receiving rejection cases; these do not emulate native macOS."""

import copy
import tempfile
import io
import tarfile
from pathlib import Path
import unittest

from macos_cold_ollama_bootstrap import (
    SOURCE_PATHS,
    compare_installed_archive,
    digest,
    sandbox_profile,
    validate,
)


class ColdReceiptTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        driver = Path(self.root.name) / "driver"
        source = driver / "modules/llm/ensure-ollama-deps.sh"
        source.parent.mkdir(parents=True)
        source.write_text("independent source bytes\n")
        self.config = {
            "driver": str(driver),
            "architecture": "x86_64",
            "denied_runtime_paths": ["/usr/bin/python3"],
            "install_dir": str(Path(self.root.name) / "install"),
        }
        self.result = {
            "success": True,
            "python_resolver": "unmodified production resolver",
            "ollama_resolver": "unmodified production resolver",
            "python_state": "python_missing",
            "native_python_candidates_count": 0,
            "denied_runtime_paths": ["/usr/bin/python3"],
            "daemon_validation": "not-executed",
            "native_environment": {
                "PROJECT_ROOT": str(driver),
                "ERGOPTI_NATIVE_ARCH": "x86_64",
                "ERGOPTI_NATIVE_PYTHONS": "",
                "ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN": "",
                "ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR": self.config["install_dir"],
                "ERGOPTI_BOOTSTRAP_PYTHON": "",
            },
            "state": "ready",
            "runtime_installed": True,
            "runtime": "native Hammerspoon",
            "tasks": 1,
            "absent_python_selected": True,
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
        self.assertIn("macos/modules/llm/ensure-ollama-deps.sh", SOURCE_PATHS)
        self.assertNotIn("macos/modules/llm/ensure-mlx-deps.sh", SOURCE_PATHS)
        self.assertIn("macos/modules/llm/ollama_binary.lua", SOURCE_PATHS)
        self.assertIn("macos/modules/llm/ollama-release.sh", SOURCE_PATHS)

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

    def test_six_actual_official_inputs_and_explicit_selection_required(self):
        for key in tuple(self.result["native_environment"]):
            changed = copy.deepcopy(self.result)
            changed["native_environment"][key] = "foreign"
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                validate(changed, self.config)
        for key, value in (
            ("daemon_validation", "passed"),
            ("python_resolver", "forced-missing-adapter"),
        ):
            changed = copy.deepcopy(self.result)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                validate(changed, self.config)

    def test_actual_isolation_resolvers_and_denied_paths_required(self):
        for key, value in (
            ("python_resolver", "forced-missing"),
            ("ollama_resolver", "managed-only"),
            ("native_python_candidates_count", True),
            ("native_python_candidates_count", 1),
            ("denied_runtime_paths", []),
            ("python_state", "ready"),
        ):
            changed = copy.deepcopy(self.result)
            changed[key] = value
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                validate(changed, self.config)
        lua = Path(__file__).with_name("macos_cold_ollama_bootstrap.lua").read_text()
        self.assertNotIn("python.resolve =", lua)
        self.assertNotIn("python.native_candidates =", lua)
        self.assertNotIn("binary.candidates =", lua)
        self.assertIn("local selected, state = python.resolve()", lua)
        self.assertIn("assert(binary.resolve() == nil", lua)

    def test_exact_literal_scoped_kernel_deny_profile(self):
        self.assertEqual(
            sandbox_profile(["/usr/bin/python3", "/opt/homebrew/bin/ollama"]),
            "(version 1)\n(allow default)\n(deny file-read* process-exec\n"
            '  (literal "/usr/bin/python3")\n'
            '  (literal "/opt/homebrew/bin/ollama")\n)\n',
        )


class InstalledArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.directory = self.root / "installed"
        self.directory.mkdir()
        self.archive = self.root / "official.tgz"
        self.bytes = b"independent Mach-O stand-in bytes for portable member policy only\n"
        with tarfile.open(self.archive, "w:gz") as output:
            member = tarfile.TarInfo("./ollama")
            member.mode, member.size = 0o755, len(self.bytes)
            output.addfile(member, io.BytesIO(self.bytes))
            member = tarfile.TarInfo("./lib")
            member.type, member.mode = tarfile.DIRTYPE, 0o755
            output.addfile(member)
            member = tarfile.TarInfo("./lib/example.dylib")
            member.mode, member.size = 0o644, 3
            output.addfile(member, io.BytesIO(b"lib"))
            member = tarfile.TarInfo("./lib/alias.dylib")
            member.type, member.linkname = tarfile.SYMTYPE, "example.dylib"
            output.addfile(member)
        # The tiny archive is independently authored; never invoke production
        # extraction, native codesign or claim this fixture is a real binary.
        (self.directory / "ollama").write_bytes(self.bytes)
        (self.directory / "ollama").chmod(0o755)
        (self.directory / "lib").mkdir(mode=0o755)
        (self.directory / "lib").chmod(0o755)
        (self.directory / "lib/example.dylib").write_bytes(b"lib")
        (self.directory / "lib/example.dylib").chmod(0o644)
        (self.directory / "lib/alias.dylib").symlink_to("example.dylib")

    def test_independent_member_bytes_links_and_inventory(self):
        files = compare_installed_archive(self.archive, self.directory)
        self.assertEqual(set(files), {"ollama", "lib/example.dylib"})
        self.assertEqual(files["ollama"], digest(self.directory / "ollama"))

    def test_changed_library_refuses(self):
        (self.directory / "lib/example.dylib").write_bytes(b"bad")
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)

    def test_extra_runtime_file_refuses(self):
        (self.directory / "injected.dylib").write_bytes(b"extra")
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)

    def test_symlink_external_bytes_refuse(self):
        outside = self.root / "external"
        outside.write_bytes(b"lib")
        link = self.directory / "lib/alias.dylib"
        link.unlink()
        link.symlink_to(outside)
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)

    def test_wrong_executable_mode_refuses(self):
        (self.directory / "ollama").chmod(0o644)
        with self.assertRaises(RuntimeError):
            compare_installed_archive(self.archive, self.directory)


if __name__ == "__main__":
    unittest.main()
