"""Caller root ownership controls; actual POSIX files/FD, native owner modeled.

The original bootstrap/teardown methods execute through fixed test source paths.
No native compiler, signing, Security, permission or clock qualification is given.
"""

import hashlib
import importlib.abc
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
PACKET = ROOT
REPOSITORY = ROOT
SUPPORT = ROOT / "static/ergopti_plus/macos/tests/support"
FACTS = {}
RECEIVING = []


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ModeledNativeOwner:
    """Only compiler/signing/Security are modeled; root replacement is real."""

    native = True
    groups = object()
    closed = False
    trust_attempted = False
    keychain_created = False

    def __init__(self):
        self.command_group_debt = []
        self.command_file_debt = []
        self.calls = []
        self.close_calls = 0

    def _command(self, arguments, *, timeout=15, deadline=None):
        self.calls.append((list(arguments), timeout, deadline))
        if arguments[:2] == ["/usr/bin/xcrun", "swiftc"]:
            executable = Path(arguments[arguments.index("-o") + 1])
            executable.write_bytes(b"EXPLICIT MODELED SWIFT IMAGE: NO NATIVE CREDIT\n")
            executable.chmod(0o700)
        return 0, b""

    def close(self):
        self.close_calls += 1
        self.closed = True

    def receiving_facts(self):
        return {"active": 0}


class RootReplacementControl(unittest.TestCase):
    def test_same_name_foreign_root_survives_actual_bootstrap_cleanup(self):
        client_path = SUPPORT / "native_http_wire_client_receiving.py"
        builder_path = SUPPORT / "native_http_fixture_builder.py"
        FACTS["client_sha256"] = hashlib.sha256(client_path.read_bytes()).hexdigest()
        FACTS["builder_sha256"] = hashlib.sha256(builder_path.read_bytes()).hexdigest()
        FACTS["qualification"] = "actual POSIX files; modeled compiler/Security; no native credit"
        client = load("root_replacement_real_client", client_path)
        real_spec = importlib.util.spec_from_file_location
        real_mkdtemp = tempfile.mkdtemp
        owner = ModeledNativeOwner()
        with tempfile.TemporaryDirectory(prefix="ergopti-root-counter-") as outer_name:
            outer = Path(outer_name)
            self.addCleanup(
                lambda: FACTS.update(outer_private_directory_retired=not outer.exists())
            )
            source_root = outer / "source"
            source_root.mkdir(mode=0o700)
            state = {}

            class BuilderLoader(importlib.abc.Loader):
                def create_module(self, spec):
                    return None

                def exec_module(self, module):
                    module.__file__ = str(builder_path)
                    exec(
                        compile(builder_path.read_bytes(), str(builder_path), "exec"),
                        module.__dict__,
                    )
                    module.ROOT = source_root
                    for relative in module.SOURCE_INPUTS:
                        source = PACKET / relative
                        if not source.is_file():
                            source = REPOSITORY / relative
                        target = source_root / relative
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(source.read_bytes())
                    original = module.OwnedFixtureBuild

                    class ReplacedAfterRealBuild(original):
                        def _root_owned(self):
                            try:
                                return super()._root_owned()
                            except module.BuildRefused as failure:
                                state.setdefault("root_refusal", failure)
                                raise

                        def build(self):
                            result = super().build()
                            retained = self.root.with_name(self.root.name + "-exact-owned")
                            self.root.rename(retained)
                            self.root.mkdir(mode=0o700)
                            marker = self.root / "foreign-owner-marker"
                            marker.write_bytes(b"KEEP FOREIGN ROOT\n")
                            state.update(root=self.root, retained=retained, marker=marker)
                            FACTS["owned_root_identity"] = [
                                self.root_identity.st_dev,
                                self.root_identity.st_ino,
                            ]
                            foreign = self.root.lstat()
                            FACTS["foreign_root_identity"] = [
                                foreign.st_dev,
                                foreign.st_ino,
                            ]
                            FACTS["foreign_present_before_environment"] = marker.is_file()
                            return result

                    module.OwnedFixtureBuild = ReplacedAfterRealBuild

            def builder_spec(name, location, *arguments, **keywords):
                if name == "owned_native_http_build":
                    self.assertEqual(Path(location), builder_path)
                    return importlib.util.spec_from_loader(name, BuilderLoader())
                return real_spec(name, location, *arguments, **keywords)

            def private_mkdtemp(*arguments, **keywords):
                keywords["dir"] = outer
                return real_mkdtemp(*arguments, **keywords)

            caught = None
            try:
                with (
                    mock.patch.object(sys, "platform", "darwin"),
                    mock.patch.dict(
                        sys.modules,
                        {
                            "httpx": SimpleNamespace(__version__="0.28.1"),
                            "huggingface_hub": SimpleNamespace(__version__="1.13.0"),
                        },
                    ),
                    mock.patch.object(client.wire, "WireFixture", return_value=owner),
                    mock.patch.object(
                        importlib.util,
                        "spec_from_file_location",
                        side_effect=builder_spec,
                    ),
                    mock.patch.object(tempfile, "mkdtemp", side_effect=private_mkdtemp),
                ):
                    try:
                        client.RealNativeClientReceiving.setUpClass()
                    except BaseException as failure:
                        caught = failure
                FACTS.update(
                    bootstrap_failure_type=type(caught).__name__,
                    exact_root_refusal_preserved=caught is state.get("root_refusal"),
                    fixture_close_calls=owner.close_calls,
                    fixture_closed=owner.closed,
                    foreign_present_after_bootstrap=state["marker"].is_file(),
                    retained_owned_root_present=state["retained"].is_dir(),
                    modeled_command_count=len(owner.calls),
                    command_group_debt=len(owner.command_group_debt),
                    command_file_debt=len(owner.command_file_debt),
                )
                self.assertIs(caught, state["root_refusal"])
                self.assertEqual(owner.close_calls, 1)
                self.assertTrue(owner.closed)
                self.assertTrue(state["retained"].is_dir())
                self.assertTrue(
                    state["marker"].is_file(),
                    "Caller deleted a genuine same-name foreign root",
                )
            finally:
                # The exact private outer owner retires both genuine names.
                for key in ("root", "retained"):
                    path = state.get(key)
                    if path is not None and path.exists():
                        shutil.rmtree(path)
                FACTS["outer_exact_root_names_retired"] = all(
                    not state[key].exists() for key in ("root", "retained") if key in state
                )
        FACTS["outer_private_directory_retired"] = not outer.exists()


class CleanupOwner:
    def __init__(self):
        self.closed = False
        self.command_group_debt = []
        self.command_file_debt = []
        self.trust_attempted = False
        self.keychain_created = False
        self.active = 0
        self.close_failure = None
        self.close_calls = 0

    def close(self):
        self.close_calls += 1
        if self.close_failure is not None:
            raise self.close_failure
        self.closed = True

    def receiving_facts(self):
        return {"active": self.active}


class ClientRootCleanupControls(unittest.TestCase):
    def setUp(self):
        self.private = tempfile.TemporaryDirectory(prefix="ergopti-root-closure-")
        self.outer = Path(self.private.name)
        self.client = load(
            "actual_cleanup_client", SUPPORT / "native_http_wire_client_receiving.py"
        )
        self.builder = load("actual_cleanup_builder", SUPPORT / "native_http_fixture_builder.py")
        self.owner = CleanupOwner()
        self.build = self.builder.OwnedFixtureBuild(self.owner, parent=self.outer)
        self.receipt = {
            "source_hashes": {},
            "binary_sha256": hashlib.sha256(b"EXPLICIT MODELED IMAGE").hexdigest(),
        }
        self.build.executable.parent.mkdir(parents=True)
        self.build.executable.write_bytes(b"EXPLICIT MODELED IMAGE")
        self.build.executable.chmod(0o700)
        self.build.receipt_path.write_text(json.dumps(self.receipt))
        self.primary = RuntimeError("EXACT MODELED BUILD FAILURE")
        self.descriptor = None
        self.renamed = None
        self.observation = {
            "method": self._testMethodName,
            "qualification": "actual POSIX files/FD; modeled native owner/Security",
        }

    def tearDown(self):
        if self.descriptor is not None:
            os.close(self.descriptor)
            self.descriptor = None
        self.private.cleanup()
        self.observation["outer_private_directory_retired"] = not self.outer.exists()
        self.observation["exact_outer_descriptor_retired"] = self.descriptor is None
        RECEIVING.append(self.observation)

    def bootstrap_failure(self):
        real_spec = importlib.util.spec_from_file_location
        build = self.build
        primary = self.primary

        class FailureBuild:
            def __new__(cls, fixture):
                self.assertIs(fixture, self.owner)
                return build

        class BuilderLoader(importlib.abc.Loader):
            def create_module(self, spec):
                return None

            def exec_module(self, module):
                module.OwnedFixtureBuild = FailureBuild

        def specific_spec(name, path, *arguments, **keywords):
            if name == "owned_native_http_build":
                self.assertEqual(Path(path), SUPPORT / "native_http_fixture_builder.py")
                return importlib.util.spec_from_loader(name, BuilderLoader())
            return real_spec(name, path, *arguments, **keywords)

        caught = None
        with (
            mock.patch.object(sys, "platform", "darwin"),
            mock.patch.dict(
                sys.modules,
                {
                    "httpx": SimpleNamespace(__version__="0.28.1"),
                    "huggingface_hub": SimpleNamespace(__version__="1.13.0"),
                },
            ),
            mock.patch.object(self.client.wire, "WireFixture", return_value=self.owner),
            mock.patch.object(importlib.util, "spec_from_file_location", side_effect=specific_spec),
            mock.patch.object(self.build, "build", side_effect=primary),
        ):
            try:
                self.client.RealNativeClientReceiving.setUpClass()
            except BaseException as failure:
                caught = failure
        self.observation.update(
            exact_primary=caught is primary,
            close_calls=self.owner.close_calls,
            root_present=self.build.root.exists(),
        )
        return caught

    def prepare_teardown(self):
        cls = self.client.RealNativeClientReceiving
        cls.fixture = self.owner
        cls.build = self.build
        cls.root = self.build.root
        cls.environment = {"ERGOPTI_LAUNCHER_EXECUTABLE": str(self.build.executable)}
        cls.receiving_workers = []
        return cls

    def capture_debt(self):
        self.descriptor = os.open(
            self.build.root / "physical-capture", os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600
        )
        self.owner.command_file_debt.append(SimpleNamespace(descriptor=self.descriptor))

    def test01OwnedBootstrapCleanupPreservesPrimary(self):
        caught = self.bootstrap_failure()
        self.assertIs(caught, self.primary)
        self.assertEqual(self.owner.close_calls, 1)
        self.assertFalse(self.build.root.exists())

    def test02BootstrapCaptureDebtRetainsRootAndPhysicalFD(self):
        self.capture_debt()
        caught = self.bootstrap_failure()
        self.assertIs(caught, self.primary)
        self.assertIsInstance(caught.__cause__, RuntimeError)
        self.assertEqual(self.owner.close_calls, 1)
        self.assertTrue(self.build.root.is_dir())
        self.assertEqual(os.fstat(self.descriptor).st_nlink, 1)
        self.observation["capture_fd_open_before_outer_cleanup"] = True

    def test03BootstrapCloseFailurePreservesExactPrimary(self):
        close_failure = OSError("EXACT MODELED PHYSICAL CLOSE FAILURE")
        self.owner.close_failure = close_failure
        caught = self.bootstrap_failure()
        self.assertIs(caught, self.primary)
        self.assertIs(caught.__cause__, close_failure)
        self.assertEqual(self.owner.close_calls, 1)
        self.assertFalse(self.owner.closed)
        self.assertTrue(self.build.root.is_dir())
        self.assertIs(self.client.RealNativeClientReceiving.root_cleanup_failures[0], close_failure)

    def test04OwnedTeardownRunsOriginalReceiptChecksThenRemovesRoot(self):
        cls = self.prepare_teardown()
        cls.tearDownClass()
        self.assertEqual(self.owner.close_calls, 1)
        self.assertFalse(self.build.root.exists())
        self.observation["root_present"] = self.build.root.exists()

    def test05ForeignTeardownRootSurvivesBeforeReceiptReads(self):
        cls = self.prepare_teardown()
        self.renamed = self.build.root.with_name(self.build.root.name + "-exact-owned")
        self.build.root.rename(self.renamed)
        shutil.copytree(self.renamed, self.build.root)
        marker = self.build.root / "foreign-owner-marker"
        marker.write_bytes(b"KEEP FOREIGN ROOT")
        with self.assertRaises(self.builder.BuildRefused):
            cls.tearDownClass()
        self.assertEqual(self.owner.close_calls, 1)
        self.assertTrue(marker.is_file())
        self.assertTrue(self.renamed.is_dir())
        self.observation.update(
            foreign_root_retained=marker.is_file(), exact_owned_root_retained=self.renamed.is_dir()
        )

    def test06TeardownCaptureDebtRetainsRootAndPhysicalFD(self):
        self.capture_debt()
        cls = self.prepare_teardown()
        with self.assertRaisesRegex(RuntimeError, "root cleanup remains unsettled"):
            cls.tearDownClass()
        self.assertEqual(self.owner.close_calls, 1)
        self.assertTrue(self.build.root.is_dir())
        self.assertEqual(os.fstat(self.descriptor).st_nlink, 1)
        self.observation.update(
            root_present=self.build.root.is_dir(), capture_fd_open_before_outer_cleanup=True
        )


EXPECTED_TEST_IDENTITIES = {
    "RootReplacementControl": ("test_same_name_foreign_root_survives_actual_bootstrap_cleanup",),
    "ClientRootCleanupControls": (
        "test01OwnedBootstrapCleanupPreservesPrimary",
        "test02BootstrapCaptureDebtRetainsRootAndPhysicalFD",
        "test03BootstrapCloseFailurePreservesExactPrimary",
        "test04OwnedTeardownRunsOriginalReceiptChecksThenRemovesRoot",
        "test05ForeignTeardownRootSurvivesBeforeReceiptReads",
        "test06TeardownCaptureDebtRetainsRootAndPhysicalFD",
    ),
}


def enrolled_cases():
    """Fixed1+6 caller controls; absent or extra methods refuse enrollment."""
    classes = (RootReplacementControl, ClientRootCleanupControls)
    for case in classes:
        if (
            case.__module__ != __name__
            or tuple(unittest.defaultTestLoader.getTestCaseNames(case))
            != EXPECTED_TEST_IDENTITIES[case.__name__]
        ):
            raise RuntimeError("Native client root control identity refused")
    if sum(len(EXPECTED_TEST_IDENTITIES[case.__name__]) for case in classes) != 7:
        raise RuntimeError("Native client root control census refused")
    return classes
