# tools/diagnostics/macos_native_wire_swift_dependencies_test.py
"""Actual standalone source preparation; Apple compiler and clients unexecuted."""

import hashlib
import os
from pathlib import Path
import shutil
import tempfile
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ERGOPTI_RECEIVING_REPOSITORY", ROOT))
RELATIVE = "static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py"


class CompilerBoundary(Exception):
    pass


class StandaloneSwiftDependencies(unittest.TestCase):
    def setUp(self):
        self.module = ModuleType("actual_wire_dependency_recipe")
        self.module.__file__ = str(SOURCE / RELATIVE)
        code = (ROOT / RELATIVE).read_bytes()
        exec(compile(code, self.module.__file__, "exec"), self.module.__dict__)
        self.module.ROOT = SOURCE
        self.module.MAC = SOURCE / "static/ergopti_plus/macos"
        self.closed = []
        self.arguments = []
        self.inspect = lambda arguments: None
        control = self

        class FixturePort:
            def _command(self, arguments, *, timeout):
                control.arguments.append(arguments)
                control.assertEqual(timeout, 60)
                control.inspect(arguments)

            def close(self):
                control.closed.append(True)

        self.fixture = FixturePort

    def run_recipe(self):
        with (
            patch.object(self.module.sys, "platform", "darwin"),
            patch.object(self.module.wire, "WireFixture", self.fixture),
            patch.dict(
                sys.modules,
                {
                    "httpx": SimpleNamespace(__version__="0.28.1"),
                    "huggingface_hub": SimpleNamespace(__version__="1.13.0"),
                },
            ),
        ):
            self.module.RealNativeClientReceiving.setUpClass()

    def assert_retired(self):
        self.assertEqual(self.closed, [True])
        self.assertFalse(self.module.RealNativeClientReceiving.root.exists())

    def test_compiler_receives_exact_real_certificate_and_generated_policy_sources(self):
        def inspect(arguments):
            self.assertEqual(arguments[:3], ["/usr/bin/xcrun", "swiftc", "-parse-as-library"])
            private = self.module.RealNativeClientReceiving.root
            for name in (
                "ManagedHTTPWorker.swift",
                "ManagedCertificateAuthorities.swift",
                "ManagedBootstrapPolicy.generated.swift",
            ):
                copied = private / name
                original = self.module.MAC / "launcher/Sources/ErgoptiPlus" / name
                self.assertIn(str(copied), arguments)
                self.assertEqual(copied.read_bytes(), original.read_bytes())
                self.assertEqual(
                    hashlib.sha256(copied.read_bytes()).digest(),
                    hashlib.sha256(original.read_bytes()).digest(),
                )
            raise CompilerBoundary()

        self.inspect = inspect
        with self.assertRaises(CompilerBoundary):
            self.run_recipe()
        self.assertEqual(len(self.arguments), 1)
        self.assert_retired()

    def test_modified_certificate_copy_refuses_before_compiler(self):
        copy = self.module.shutil.copy2

        def mutate(source, destination, *arguments, **options):
            result = copy(source, destination, *arguments, **options)
            if Path(destination).name == "ManagedCertificateAuthorities.swift":
                Path(destination).write_bytes(b"foreign native trust source")
            return result

        self.inspect = lambda arguments: self.fail("modified source reached compiler")
        with patch.object(self.module.shutil, "copy2", mutate):
            with self.assertRaisesRegex(
                RuntimeError, "Native Swift source changed before compilation"
            ):
                self.run_recipe()
        self.assertEqual(self.arguments, [])
        self.assert_retired()

    def test_modified_generated_policy_copy_refuses_before_compiler(self):
        copy = self.module.shutil.copy2

        def mutate(source, destination, *arguments, **options):
            result = copy(source, destination, *arguments, **options)
            if Path(destination).name == "ManagedBootstrapPolicy.generated.swift":
                Path(destination).write_bytes(b"foreign route policy source")
            return result

        self.inspect = lambda arguments: self.fail("modified source reached compiler")
        with patch.object(self.module.shutil, "copy2", mutate):
            with self.assertRaisesRegex(
                RuntimeError, "Native Swift source changed before compilation"
            ):
                self.run_recipe()
        self.assertEqual(self.arguments, [])
        self.assert_retired()

    def test_compile_time_source_change_refuses_before_signature_admission(self):
        def inspect(arguments):
            private = self.module.RealNativeClientReceiving.root
            (private / "ManagedBootstrapPolicy.generated.swift").write_bytes(
                b"changed after compiler acquisition"
            )

        self.inspect = inspect
        with self.assertRaisesRegex(RuntimeError, "Native Swift source changed during compilation"):
            self.run_recipe()
        self.assertEqual(len(self.arguments), 1)
        self.assert_retired()

    def missing_source(self, name):
        with tempfile.TemporaryDirectory(prefix="ergopti-missing-wire-source-") as directory:
            source = Path(directory)
            for relative in (
                "static/ergopti_plus/_shared/modules/network/proxy_policy.json",
                "static/ergopti_plus/_shared/python/network_proxy_policy.py",
                "static/ergopti_plus/macos/platform/network/native_http.py",
                "static/ergopti_plus/macos/platform/network/managed_http.py",
                "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift",
                "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedCertificateAuthorities.swift",
                "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedBootstrapPolicy.generated.swift",
            ):
                destination = source / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(SOURCE / relative, destination)
            missing = source / "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus" / name
            missing.unlink()
            self.module.ROOT = source
            self.module.MAC = source / "static/ergopti_plus/macos"
            with self.assertRaises(FileNotFoundError):
                self.run_recipe()
            self.assertEqual(self.arguments, [])
            self.assert_retired()
            self.assertFalse(missing.exists())

    def test_missing_real_certificate_source_retires_before_compiler(self):
        self.missing_source("ManagedCertificateAuthorities.swift")

    def test_missing_real_generated_policy_retires_before_compiler(self):
        self.missing_source("ManagedBootstrapPolicy.generated.swift")

    def test_root_acquisition_failure_retires_fixture_without_foreign_cleanup(self):
        with patch.object(self.module.tempfile, "mkdtemp", side_effect=OSError("create refused")):
            with self.assertRaisesRegex(OSError, "create refused"):
                self.run_recipe()
        self.assertEqual(self.closed, [True])
        self.assertEqual(self.arguments, [])
        self.assertIsNone(self.module.RealNativeClientReceiving.root)


if __name__ == "__main__":
    unittest.main()
