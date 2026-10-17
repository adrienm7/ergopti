# tools/diagnostics/macos_native_wire_swift_dependencies_test.py
"""Actual standalone source preparation; Apple compiler and clients unexecuted."""

import hashlib
import importlib.abc
import importlib.util
import os
import re
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
BUILDER = "static/ergopti_plus/macos/tests/support/native_http_fixture_builder.py"
# Independent recipe fixture: do not regenerate this list from the builder.
RECIPE_INPUTS = (
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift",
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedPACSource.swift",
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedCertificateAuthorities.swift",
    "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedBootstrapPolicy.generated.swift",
    "static/ergopti_plus/macos/tests/support/native_http_fixture_main.swift",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/CPOSIXCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedProgramCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/LoopbackListenerCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedImageAliasCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedSuspendedImageCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedListenerEventCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedRuntimeSignatureCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedInstalledConfiguration.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedChildReapingCompatibility.h",
    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedVHDReportSocketIdentity.h",
    "static/ergopti_plus/macos/platform/network/native_http.py",
    "static/ergopti_plus/macos/platform/network/managed_http.py",
    "static/ergopti_plus/_shared/python/network_proxy_policy.py",
    "static/ergopti_plus/_shared/modules/network/proxy_policy.json",
    BUILDER,
    "static/ergopti_plus/macos/tests/support/native_http_wire_fixture.py",
    "tools/diagnostics/macos_owned_process.py",
)


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
            # The Apple compiler and child owner are modeled. Actual source
            # staging, receipt verification and caller cleanup execute below.
            native = True
            groups = object()

            def __init__(self):
                self.closed = False
                self.command_group_debt = []
                self.command_file_debt = []
                self.trust_attempted = False
                self.keychain_created = False

            def _command(self, arguments, *, timeout, deadline=None):
                control.arguments.append(arguments)
                control.assertEqual(timeout, 60)
                control.assertIsNone(deadline)
                control.inspect(arguments)

            def close(self):
                control.closed.append(True)
                self.closed = True

            def receiving_facts(self):
                return {"active": 0}

        self.fixture = FixturePort

    def run_recipe(self):
        control = self
        real_spec = importlib.util.spec_from_file_location

        class BuilderLoader(importlib.abc.Loader):
            def create_module(self, spec):
                return None

            def exec_module(self, module):
                path = ROOT / BUILDER
                module.__file__ = str(path)
                exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
                module.ROOT = control.module.ROOT

        def fixed_builder_spec(name, location, *arguments, **keywords):
            if name == "owned_native_http_build":
                self.assertEqual(
                    Path(location), Path(self.module.__file__).with_name(Path(BUILDER).name)
                )
                return importlib.util.spec_from_loader(name, BuilderLoader())
            return real_spec(name, location, *arguments, **keywords)

        with (
            patch.object(self.module.sys, "platform", "darwin"),
            patch.object(self.module.wire, "WireFixture", self.fixture),
            patch.object(importlib.util, "spec_from_file_location", side_effect=fixed_builder_spec),
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
            self.assertIn("-I", arguments)
            module = Path(arguments[arguments.index("-I") + 1])
            self.assertEqual(module, private / "CPOSIXCompatibility")
            self.assertEqual(module.stat().st_mode & 0o777, 0o700)
            headers = (
                "CPOSIXCompatibility.h",
                "OwnedProgramCompatibility.h",
                "LoopbackListenerCompatibility.h",
                "OwnedImageAliasCompatibility.h",
                "OwnedSuspendedImageCompatibility.h",
                "OwnedListenerEventCompatibility.h",
                "OwnedRuntimeSignatureCompatibility.h",
                "OwnedInstalledConfiguration.h",
                "OwnedChildReapingCompatibility.h",
                "OwnedVHDReportSocketIdentity.h",
            )
            self.assertEqual({path.name for path in module.glob("*.h")}, set(headers))
            for name in headers:
                original = self.module.MAC / "launcher/Sources/CPOSIXCompatibility/include" / name
                self.assertEqual((module / name).read_bytes(), original.read_bytes())
            self.assertIn(
                '#include "OwnedListenerEventCompatibility.h"',
                (module / "CPOSIXCompatibility.h").read_text(),
            )
            for header in module.glob("*.h"):
                for required in re.findall(
                    rb'^\s*#\s*include\s*"([^"\r\n]+)"', header.read_bytes(), re.MULTILINE
                ):
                    dependency = module / required.decode("ascii")
                    self.assertTrue(
                        dependency.is_file(), f"Missing staged quoted header: {required!r}"
                    )
            raise CompilerBoundary()

        self.inspect = inspect
        with self.assertRaises(CompilerBoundary):
            self.run_recipe()
        self.assertEqual(len(self.arguments), 1)
        self.assert_retired()

    def test_modified_certificate_copy_refuses_before_compiler(self):
        write = Path.write_bytes

        def mutate(destination, content):
            result = write(destination, content)
            if Path(destination).name == "ManagedCertificateAuthorities.swift":
                write(destination, b"foreign native trust source")
            return result

        self.inspect = lambda arguments: self.fail("modified source reached compiler")
        with patch.object(Path, "write_bytes", mutate):
            with self.assertRaisesRegex(
                RuntimeError, "Native fixture staged source receipt diverged"
            ):
                self.run_recipe()
        self.assertEqual(self.arguments, [])
        self.assert_retired()

    def test_modified_generated_policy_copy_refuses_before_compiler(self):
        write = Path.write_bytes

        def mutate(destination, content):
            result = write(destination, content)
            if Path(destination).name == "ManagedBootstrapPolicy.generated.swift":
                write(destination, b"foreign route policy source")
            return result

        self.inspect = lambda arguments: self.fail("modified source reached compiler")
        with patch.object(Path, "write_bytes", mutate):
            with self.assertRaisesRegex(
                RuntimeError, "Native fixture staged source receipt diverged"
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
        with self.assertRaisesRegex(RuntimeError, "Native fixture staged source receipt diverged"):
            self.run_recipe()
        self.assertEqual(len(self.arguments), 1)
        self.assert_retired()

    def missing_source(self, name):
        with tempfile.TemporaryDirectory(prefix="ergopti-missing-wire-source-") as directory:
            source = Path(directory)
            for relative in RECIPE_INPUTS:
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

    def test_missing_public_umbrella_dependency_retires_before_compiler(self):
        for name in (
            "OwnedRuntimeSignatureCompatibility.h",
            "OwnedInstalledConfiguration.h",
            "OwnedChildReapingCompatibility.h",
            "OwnedVHDReportSocketIdentity.h",
        ):
            with self.subTest(header=name):
                with tempfile.TemporaryDirectory(
                    prefix="ergopti-missing-wire-header-"
                ) as directory:
                    source = Path(directory)
                    for relative in RECIPE_INPUTS:
                        destination = source / relative
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(SOURCE / relative, destination)
                    missing = (
                        source
                        / "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include"
                        / name
                    )
                    missing.unlink()
                    self.module.ROOT = source
                    self.module.MAC = source / "static/ergopti_plus/macos"
                    with self.assertRaises(FileNotFoundError):
                        self.run_recipe()
                    self.assertEqual(self.arguments, [])
                    self.assert_retired()
                    self.assertFalse(missing.exists())
                self.closed.clear()

    def test_root_acquisition_failure_retires_fixture_without_foreign_cleanup(self):
        with patch.object(tempfile, "mkdtemp", side_effect=OSError("create refused")):
            with self.assertRaisesRegex(OSError, "create refused"):
                self.run_recipe()
        self.assertEqual(self.closed, [True])
        self.assertEqual(self.arguments, [])
        self.assertIsNone(self.module.RealNativeClientReceiving.root)

    def test_compiler_receives_exact_real_pac_source_owner(self):
        def inspect(arguments):
            copied = self.module.RealNativeClientReceiving.root / "ManagedPACSource.swift"
            original = self.module.MAC / "launcher/Sources/ErgoptiPlus/ManagedPACSource.swift"
            self.assertIn(str(copied), arguments)
            self.assertEqual(copied.read_bytes(), original.read_bytes())
            raise CompilerBoundary()

        self.inspect = inspect
        with self.assertRaises(CompilerBoundary):
            self.run_recipe()
        self.assertEqual(len(self.arguments), 1)
        self.assert_retired()

    def test_modified_pac_source_copy_refuses_before_compiler(self):
        write = Path.write_bytes

        def mutate(destination, content):
            result = write(destination, content)
            if Path(destination).name == "ManagedPACSource.swift":
                write(destination, b"foreign PAC source owner")
            return result

        self.inspect = lambda arguments: self.fail("modified PAC source reached compiler")
        with patch.object(Path, "write_bytes", mutate):
            with self.assertRaisesRegex(
                RuntimeError, "Native fixture staged source receipt diverged"
            ):
                self.run_recipe()
        self.assertEqual(self.arguments, [])
        self.assert_retired()

    def test_missing_real_pac_source_retires_before_compiler(self):
        self.missing_source("ManagedPACSource.swift")


if __name__ == "__main__":
    unittest.main()
