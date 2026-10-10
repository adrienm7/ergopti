# tools/test/macos_managed_ollama_catalogue_refusal_test.py
"""Real filesystem/CLI receiving with modeled host admission; no native credit."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import runpy
import signal
import stat
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = "static/ergopti_plus/macos/modules/llm/managed_ollama_runtime.py"
INPUTS = (
    RUNTIME,
    "static/ergopti_plus/macos/modules/llm/managed_bootstrap_http.py",
    "static/ergopti_plus/_shared/python/managed_ollama_runtime.py",
    "static/ergopti_plus/_shared/python/network_proxy_policy.py",
    "static/ergopti_plus/_shared/python/managed_source_alias.py",
    "static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json",
)
GENERIC = "Managed Ollama runtime admission refused.\n"
MISSING = "OLLAMA_MANAGED_CATALOGUE_MISSING\n"
OBSERVATIONS = []
ACTIVE_FENCE = None


def audit(event, arguments):
    fence = ACTIVE_FENCE
    if fence is None:
        return
    forbidden = event in {
        "subprocess.Popen",
        "os.system",
        "os.posix_spawn",
        "os.exec",
        "os.fork",
        "socket.connect",
        "socket.bind",
        "ctypes.dlopen",
        "os.mkdir",
        "os.rename",
        "os.remove",
        "os.rmdir",
        "os.chmod",
        "os.link",
        "os.symlink",
    }
    if event == "open":
        name, mode, flags = arguments
        forbidden = (
            forbidden
            or (isinstance(mode, str) and any(value in mode for value in "wax+"))
            or (type(flags) is int and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC))
        )
        if isinstance(name, (str, bytes)) and os.fsdecode(name) == fence["catalogue"]:
            fence["catalogue_reads"] += 1
    if forbidden:
        fence["forbidden"].append(event)
        raise RuntimeError("Catalogue receiving dispatched a forbidden native effect")


sys.addaudithook(audit)


class CatalogueRefusalTests(unittest.TestCase):
    def setUp(self):
        if os.name != "posix" or os.geteuid() == 0:
            raise RuntimeError("Catalogue receiving requires actual nonroot POSIX permissions")
        self.owned = tempfile.TemporaryDirectory(prefix="ergopti-catalogue-receiving-")
        self.addCleanup(self.owned.cleanup)
        owned_root = Path(self.owned.name).resolve(strict=True)
        self.payload = owned_root / "payload"
        self.source_bytes = {}
        for relative in INPUTS:
            source = ROOT / relative
            fact = source.lstat()
            self.assertTrue(stat.S_ISREG(fact.st_mode) and not source.is_symlink())
            self.source_bytes[relative] = source.read_bytes()
            target = self.payload / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(self.source_bytes[relative])
        self.runtime = self.payload / RUNTIME
        self.contract = self.payload / INPUTS[-1]
        self.catalogue = self.contract.with_name("managed_ollama_release.json")
        self.home = owned_root / "home"
        self.home.mkdir()
        self.service = self.home / "old-service-sentinel"
        self.models = self.home / "model-store-sentinel"
        self.service.write_bytes(b"independent existing service remains untouched")
        self.models.write_bytes(b"independent existing model store remains untouched")
        # Import all genuine helper declarations on the actual host FIRST.
        # No inputs(), native request, installer or Darwin helper is mocked.
        actual_platform = sys.platform
        specification = importlib.util.spec_from_file_location(
            "catalogue_actual_host_" + self._testMethodName, self.runtime
        )
        self.helper = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(self.helper)
        self.assertEqual(sys.platform, actual_platform)
        self.assertTrue(callable(self.helper.inputs) and callable(self.helper.install))
        self.actual_platform = actual_platform

    def _tree(self):
        result = {}
        for path in Path(self.owned.name).rglob("*"):
            fact = path.lstat()
            relative = str(path.relative_to(self.owned.name))
            if stat.S_ISREG(fact.st_mode):
                # Do not invent access to a genuinely mode000 input.
                digest = (
                    None
                    if fact.st_mode & 0o444 == 0
                    else hashlib.sha256(path.read_bytes()).hexdigest()
                )
                result[relative] = ["file", fact.st_mode, fact.st_size, digest]
            elif stat.S_ISDIR(fact.st_mode):
                result[relative] = ["directory", fact.st_mode]
            else:
                raise AssertionError("Unexpected receiving namespace identity")
        return result

    def receive(self, action="install", *, direct=None, admission="darwin_model"):
        global ACTIVE_FENCE
        before = self._tree()
        before_originals = {
            name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in INPUTS
        }
        fence = {
            "catalogue": str(self.catalogue),
            "catalogue_reads": 0,
            "inputs_calls": 0,
            "input_errors": [],
            "forbidden": [],
            "admission": admission,
        }
        argv, actual_platform, machine, previous_trace = (
            sys.argv,
            sys.platform,
            platform.machine,
            sys.gettrace(),
        )
        signals = {
            name: signal.getsignal(name) for name in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
        }
        home = os.environ.get("HOME")
        out, err = io.StringIO(), io.StringIO()
        status, thrown = None, None

        def trace(frame, event, argument):
            if frame.f_code.co_filename != str(self.runtime) or frame.f_code.co_name != "inputs":
                return None
            if event == "call":
                fence["inputs_calls"] += 1
                # Controlled platform admission, at ORIGINAL inputs() entry.
                # Kernel/filesystem/interpreter stay genuine POSIX, not Darwin.
                if admission == "darwin_model":
                    sys.platform = "darwin"
                    platform.machine = lambda: "arm64"
                elif admission == "linux":
                    sys.platform = "linux"
            elif event == "exception":
                fence["input_errors"].append(argument[0].__name__)
            return trace

        try:
            os.environ["HOME"] = str(self.home)
            sys.argv = [
                str(self.runtime),
                action,
                "--timeout",
                "5",
                "--idle-timeout",
                "5",
                "--connect-timeout",
                "5",
                "--minimum-bytes-per-second",
                "1",
                "--port",
                "11434",
            ]
            ACTIVE_FENCE = fence
            sys.settrace(trace)
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    if direct == "inputs":
                        self.helper.inputs()
                    elif direct == "install":
                        self.helper.install(
                            time.monotonic() + 5, 5, connect_timeout=5, minimum_bytes_per_second=1
                        )
                    else:
                        runpy.run_path(str(self.runtime), run_name="__main__")
                except SystemExit as error:
                    status = error.code
                except BaseException as error:
                    thrown = error
        finally:
            ACTIVE_FENCE = None
            sys.settrace(previous_trace)
            sys.argv, sys.platform, platform.machine = argv, actual_platform, machine
            for name, handler in signals.items():
                signal.signal(name, handler)
            if home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = home
        self.assertEqual(fence["forbidden"], [])
        self.assertEqual(self._tree(), before)
        self.assertEqual(
            {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in INPUTS},
            before_originals,
        )
        self.assertEqual(fence["inputs_calls"], 1)
        self.assertEqual(out.getvalue(), "")
        OBSERVATIONS.append(
            {
                "case": self._testMethodName,
                "action": action,
                "direct": direct,
                "admission": admission,
                "actual_host": self.actual_platform,
                "inputs_calls": fence["inputs_calls"],
                "catalogue_reads": fence["catalogue_reads"],
                "input_errors": fence["input_errors"],
                "status": status,
                "error_type": type(thrown).__name__ if thrown is not None else None,
                "missing_marker": err.getvalue() == MISSING,
                "generic_marker": err.getvalue() == GENERIC,
                "effects": 0,
                "source_and_namespace_unchanged": True,
            }
        )
        return status, err.getvalue(), thrown, fence

    def cli_refusal(self, action="install", *, expected=GENERIC, admission="darwin_model"):
        status, stderr, thrown, fence = self.receive(action, admission=admission)
        self.assertIsNone(thrown)
        self.assertIs(type(status), int)
        self.assertEqual(status, 78)
        self.assertEqual(stderr, expected)
        return fence

    def test_actual_host_import_has_no_native_effect_and_original_actions(self):
        self.assertIn('choices=("install", "verify", "create-session")', self.runtime.read_text())
        self.assertEqual(
            self.service.read_bytes(), b"independent existing service remains untouched"
        )
        self.assertEqual(
            self.models.read_bytes(), b"independent existing model store remains untouched"
        )

    def test_original_install_cli_missing_catalogue_is_named(self):
        self.cli_refusal(expected=MISSING)

    def test_original_verify_cli_missing_catalogue_is_named(self):
        self.cli_refusal("verify", expected=MISSING)

    def test_original_create_session_cli_missing_catalogue_is_named(self):
        self.cli_refusal("create-session", expected=MISSING)

    def test_original_inputs_missing_catalogue_retains_file_primary(self):
        _, _, thrown, fence = self.receive(direct="inputs")
        self.assertEqual(fence["catalogue_reads"], 1)
        self.assertEqual(type(thrown).__name__, "MissingReleaseCatalogue")
        self.assertIs(type(thrown.__cause__), FileNotFoundError)
        self.assertEqual(thrown.args, ("missing-catalogue",))

    def test_original_install_missing_catalogue_retains_file_primary(self):
        _, _, thrown, fence = self.receive(direct="install")
        self.assertEqual(fence["catalogue_reads"], 1)
        self.assertEqual(type(thrown).__name__, "MissingReleaseCatalogue")
        self.assertIs(type(thrown.__cause__), FileNotFoundError)
        self.assertEqual(thrown.args, ("missing-catalogue",))

    def test_missing_contract_remains_generic(self):
        self.contract.unlink()
        fence = self.cli_refusal()
        self.assertEqual(fence["catalogue_reads"], 0)
        self.assertIn("FileNotFoundError", fence["input_errors"])

    def test_genuine_mode000_catalogue_remains_generic(self):
        self.catalogue.write_bytes(b"independent unreadable metadata")
        self.catalogue.chmod(0)
        self.addCleanup(self.catalogue.chmod, 0o600)
        fence = self.cli_refusal()
        self.assertEqual(fence["catalogue_reads"], 1)
        self.assertIn("PermissionError", fence["input_errors"])

    def test_genuine_directory_catalogue_remains_generic(self):
        self.catalogue.mkdir()
        fence = self.cli_refusal()
        self.assertEqual(fence["catalogue_reads"], 1)
        self.assertIn("IsADirectoryError", fence["input_errors"])

    def test_genuine_malformed_present_catalogue_remains_generic(self):
        self.catalogue.write_bytes(b"{not valid JSON")
        fence = self.cli_refusal()
        self.assertEqual(fence["catalogue_reads"], 1)
        self.assertIn("RuntimeRefusal", fence["input_errors"])

    def test_genuine_empty_present_catalogue_remains_generic(self):
        self.catalogue.write_bytes(b"")
        fence = self.cli_refusal()
        self.assertEqual(fence["catalogue_reads"], 1)
        self.assertIn("RuntimeRefusal", fence["input_errors"])

    def test_linux_unsupported_stays_generic_before_metadata_read(self):
        fence = self.cli_refusal(admission="linux")
        self.assertEqual(fence["catalogue_reads"], 0)
        self.assertIn("RuntimeRefusal", fence["input_errors"])


if __name__ == "__main__":
    unittest.main()
