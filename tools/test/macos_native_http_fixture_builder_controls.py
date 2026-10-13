"""Portable owned-image/build admission controls; no native Swift or trust credit.

Actual POSIX files, query children and existing main-handler signals are used.
Native compiler/signing/Security responses are explicitly modeled. Import only
through the owning receiving-facts suite's fixed helper path and exact selector.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "static/ergopti_plus/macos/tests/support"
SOURCE = SUPPORT / "native_http_fixture_builder.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


B = load("portable_enrolled_fixture_builder", SOURCE)
W = load("portable_enrolled_fixture_wire", SUPPORT / "native_http_wire_fixture.py")
RECEIPT = {
    "version": 1,
    "export_status": 0,
    "entry_count": 1,
    "owned_status": 0,
    "owned_present": 1,
}
RECEIVING = []


class Owner:
    native = True
    groups = object()

    def __init__(self):
        self.calls = []
        self.fail = None
        self.mutate = None
        self.command_file_debt = []
        self.closed = False

    def _command(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if self.fail is not None:
            raise self.fail
        if args[0] == "/usr/bin/xcrun":
            image = Path(args[-1])
            image.write_bytes(b"EXPLICIT MODELED SWIFT IMAGE: NO NATIVE CREDIT")
            image.chmod(0o700)
            if self.mutate:
                self.mutate()
        return (0, b"")


class BuilderControls(unittest.TestCase):
    def setUp(self):
        self.private = Path(tempfile.mkdtemp(prefix="g6-builder-portable-"))
        self.repo = self.private / "repo"
        self.repo.mkdir()
        self.owner = Owner()
        self.patch = mock.patch.object(B, "ROOT", self.repo)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.platform = mock.patch.object(B.sys, "platform", "darwin")
        self.platform.start()
        self.addCleanup(self.platform.stop)
        self.addCleanup(shutil.rmtree, self.private)
        for relative in B.SOURCE_INPUTS:
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(("ACTUAL PORTABLE FILE: " + relative).encode())
        self.build = B.OwnedFixtureBuild(self.owner, parent=self.private)

    def qualified(self):
        return self.build.build()

    def test01WholeCompilerSourcesAndHeadersStagedExactly(self):
        build = self.qualified()
        self.assertEqual(len(self.owner.calls), 3)
        compile_args = self.owner.calls[0][0]
        self.assertEqual(
            [Path(p).name for p in compile_args if p.endswith(".swift")],
            [Path(p).name for p in B.SWIFT_INPUTS],
        )
        self.assertEqual(len(B.SWIFT_INPUTS), 5)
        self.assertEqual(len(B.HEADER_INPUTS), 9)
        self.assertEqual(
            tuple(Path(path).name for path in B.HEADER_INPUTS[:6]),
            (
                "CPOSIXCompatibility.h",
                "OwnedProgramCompatibility.h",
                "LoopbackListenerCompatibility.h",
                "OwnedImageAliasCompatibility.h",
                "OwnedSuspendedImageCompatibility.h",
                "OwnedListenerEventCompatibility.h",
            ),
        )
        self.assertEqual(Path(B.HEADER_INPUTS[6]).name, "OwnedRuntimeSignatureCompatibility.h")
        self.assertEqual(Path(B.HEADER_INPUTS[7]).name, "OwnedInstalledConfiguration.h")
        self.assertEqual(Path(B.HEADER_INPUTS[8]).name, "OwnedChildReapingCompatibility.h")
        for original in B.SWIFT_INPUTS:
            self.assertEqual(
                (build.root / Path(original).name).read_bytes(), (self.repo / original).read_bytes()
            )
        for original in B.HEADER_INPUTS:
            self.assertEqual(
                (build.root / "CPOSIXCompatibility" / Path(original).name).read_bytes(),
                (self.repo / original).read_bytes(),
            )
        self.assertEqual(build.verify(), build.executable)
        self.assertEqual(build.environment["ERGOPTI_LAUNCHER_INODE"], str(build.identity.st_ino))

    def test02SourceEditRefusesBeforeAnyCompilation(self):
        source = self.repo / B.SWIFT_INPUTS[0]
        source.unlink()
        source.symlink_to(self.repo / B.SWIFT_INPUTS[1])
        with self.assertRaises(B.BuildRefused):
            self.qualified()
        self.assertEqual(self.owner.calls, [])
        self.assertTrue(self.build.root.exists())

    def test03SourceEditDuringCompilerRefusesSigning(self):
        self.owner.mutate = lambda: (self.repo / B.SWIFT_INPUTS[0]).write_bytes(b"CHANGED SOURCE")
        with self.assertRaises(B.BuildRefused):
            self.qualified()
        self.assertEqual(len(self.owner.calls), 1)
        self.assertFalse(self.build.receipt_path.exists())

    def test04SourceEditAfterSigningRefusesQueryQualification(self):
        self.qualified()
        (self.repo / B.OWNER_INPUTS[0]).write_bytes(b"ALTERED BUILDER")
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test05StagedRuntimeEditRefuses(self):
        self.qualified()
        path = (
            self.build.root / "OwnedNativeHTTPFixture.app/Contents/Resources" / B.RUNTIME_INPUTS[0]
        )
        path.write_bytes(b"ALTERED RUNTIME")
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test06SameInodeImageEditRefuses(self):
        self.qualified()
        self.build.executable.write_bytes(b"ALTERED SIGNED IMAGE")
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test07SameBytesReplacementImageRefuses(self):
        self.qualified()
        original = self.build.executable.read_bytes()
        old = self.build.executable.with_name("old")
        self.build.executable.rename(old)
        self.build.executable.write_bytes(original)
        self.build.executable.chmod(0o700)
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test08ImageSymlinkRefuses(self):
        self.qualified()
        old = self.build.executable.with_name("old")
        self.build.executable.rename(old)
        self.build.executable.symlink_to(old)
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test09ImageHardlinkRefuses(self):
        self.qualified()
        os.link(self.build.executable, self.build.executable.with_name("second-link"))
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test10ImageParentDirectoryAliasRefuses(self):
        self.qualified()
        parent = self.build.executable.parent
        old = parent.with_name("MacOS-old")
        parent.rename(old)
        parent.symlink_to(old, target_is_directory=True)
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test11ReceiptEditRefuses(self):
        self.qualified()
        self.build.receipt_path.write_text("{}")
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test12ReceiptSymlinkRefuses(self):
        self.qualified()
        old = self.build.receipt_path.with_name("receipt-old")
        self.build.receipt_path.rename(old)
        self.build.receipt_path.symlink_to(old)
        with self.assertRaises(B.BuildRefused):
            self.build.verify()

    def test13CompilerFailureRetainsExactPrimaryAndRootDebt(self):
        primary = RuntimeError("EXACT modeled unsettled native child")
        self.owner.fail = primary
        with self.assertRaises(RuntimeError) as got:
            self.qualified()
        self.assertIs(got.exception, primary)
        self.assertTrue(self.build.root.exists())
        self.assertFalse(self.owner.closed)
        self.assertFalse(self.build.receipt_path.exists())
        self.assertFalse(hasattr(self.owner, "trust_query_owner"))

    def test14SigningFailureDoesNotBindImage(self):
        original = self.owner._command

        def command(args, **kwargs):
            if args[0] == "/usr/bin/codesign":
                raise RuntimeError("EXACT signing refusal")
            return original(args, **kwargs)

        self.owner._command = command
        with self.assertRaisesRegex(RuntimeError, "EXACT signing refusal"):
            self.qualified()
        self.assertFalse(hasattr(self.owner, "trust_query_owner"))
        self.assertTrue(self.build.root.exists())

    def test15ExactAbsoluteDeadlineSharedByCompileAndSigning(self):
        deadline = time.monotonic() + 3
        self.build.deadline = deadline
        self.qualified()
        self.assertEqual([k["deadline"] for _, k in self.owner.calls], [deadline] * 3)
        self.assertEqual([k["timeout"] for _, k in self.owner.calls], [60, 15, 15])

    def test16ExpiredStartupRefusesBeforeCompilerAndRetainsRoot(self):
        self.build.deadline = time.monotonic() - 1
        with self.assertRaisesRegex(B.BuildRefused, "deadline exhausted"):
            self.qualified()
        self.assertEqual(self.owner.calls, [])
        self.assertTrue(self.build.root.exists())

    def test17FixedRoleRejectsArbitrarySelectorsNonfiniteAndRenewedBudgets(self):
        for args in (
            [],
            ["/tmp/foreign-executable"],
            ["--owned-native-callee-startup", "nan"],
            ["--owned-native-callee-startup", "inf"],
            ["--owned-native-callee-startup", str(time.monotonic() - 1)],
            ["--owned-native-callee-startup", str(time.monotonic() + 60)],
            ["--owned-native-callee-startup", str(time.monotonic() + 2), "extra"],
        ):
            with self.subTest(args=args):
                with self.assertRaises(B.BuildRefused):
                    B.startup_deadline(args)
        deadline = time.monotonic() + 2
        self.assertEqual(
            B.startup_deadline(["--owned-native-callee-startup", str(deadline)]), deadline
        )

    def test18SourceDirectoryAliasRefuses(self):
        target = self.repo / B.SWIFT_INPUTS[0]
        parent = target.parent
        old = parent.with_name("original-real-directory")
        parent.rename(old)
        parent.symlink_to(old, target_is_directory=True)
        with self.assertRaises(B.BuildRefused):
            self.qualified()
        self.assertEqual(self.owner.calls, [])

    def test19RootReplacementDoesNotRemoveForeignObject(self):
        old = self.build.root.with_name(self.build.root.name + "-owned")
        self.build.root.rename(old)
        self.build.root.mkdir(mode=0o700)
        foreign = self.build.root / "foreign"
        foreign.write_bytes(b"KEEP")
        with self.assertRaises(B.BuildRefused):
            self.qualified()
        self.assertEqual(foreign.read_bytes(), b"KEEP")
        self.assertTrue(old.exists())
        self.assertEqual(self.owner.calls, [])

    def test20MandatoryOwnerRevalidationFailsBeforeOptionalQuery(self):
        fixture = W.WireFixture.__new__(W.WireFixture)
        fixture.trust_query_executable = Path("/NOT EXECUTED")
        primary = B.BuildRefused("EXACT source/image refusal")
        fixture.trust_query_owner = SimpleNamespace(verify=mock.Mock(side_effect=primary))
        fixture._command = mock.Mock()
        with self.assertRaises(B.BuildRefused) as got:
            fixture._observe_admin_trust(time.monotonic() + 1)
        self.assertIs(got.exception, primary)
        fixture._command.assert_not_called()

    def test21OwnedQueryCancellationIsNotOptional(self):
        fixture = W.WireFixture.__new__(W.WireFixture)
        fixture.trust_query_executable = Path("/NOT EXECUTED")
        fixture.trust_query_owner = SimpleNamespace(verify=lambda: fixture.trust_query_executable)
        fixture.ca = self.private / "fake.pem"
        fixture.ca.write_text("PORTABLE CERTIFICATE INPUT")
        fixture.command_fact = None
        primary = W.FixtureFailure("Native fixture cancelled")
        fixture._command = mock.Mock(side_effect=primary)
        with mock.patch.object(W.ssl, "PEM_cert_to_DER_cert", return_value=b"PORTABLE DER"):
            with self.assertRaises(W.FixtureFailure) as got:
                fixture._observe_admin_trust(time.monotonic() + 1)
        self.assertIs(got.exception, primary)

    def test23NativeProcessOwnerMissingRefusesBeforeCompilation(self):
        self.owner.groups = None
        with self.assertRaises(B.BuildRefused):
            self.qualified()
        self.assertEqual(self.owner.calls, [])

    def test24ExpiredStartupIsNotRenewedBySigning(self):
        self.build.deadline = time.monotonic() + 10
        deadline = self.build.deadline
        self.owner.mutate = lambda: setattr(self.build, "deadline", deadline)
        with mock.patch.object(
            B.time, "monotonic", side_effect=[deadline - 1, deadline - 1, deadline + 1]
        ):
            with self.assertRaisesRegex(B.BuildRefused, "deadline exhausted"):
                self.qualified()
        self.assertEqual(len(self.owner.calls), 2)
        self.assertFalse(hasattr(self.owner, "trust_query_owner"))

    def test25StartupNeverExtendsExistingSigningCommandCap(self):
        deadline = time.monotonic() + 44
        self.build.deadline = deadline
        before = time.monotonic()
        self.qualified()
        after = time.monotonic()
        self.assertEqual(self.owner.calls[0][1]["deadline"], deadline)
        for _, kwargs in self.owner.calls[1:]:
            self.assertLessEqual(kwargs["deadline"], after + 15)
            self.assertGreaterEqual(kwargs["deadline"], before + 15)
            self.assertLess(kwargs["deadline"], deadline)


class PortableImageOwner:
    """Actual POSIX image identity; explicitly NOT a signed native Swift image."""

    def __init__(self, root):
        self.path = root / "explicit-portable-owned-query-image"
        self.path.write_bytes(b"EXPLICIT PORTABLE IMAGE BINDING")
        self.identity = self.path.lstat()
        self.sha = hashlib.sha256(self.path.read_bytes()).digest()
        self.before = None

    def verify(self):
        if self.before:
            self.before()
        data, current = B.regular_bytes(self.path)
        if (current.st_dev, current.st_ino) != (
            self.identity.st_dev,
            self.identity.st_ino,
        ) or hashlib.sha256(data).digest() != self.sha:
            raise B.BuildRefused("Exact portable owner image refusal")
        return self.path


class AdmissionControls(unittest.TestCase):
    def setUp(self):
        self.fixture = W.WireFixture(native=False)
        self.addCleanup(self.fixture.close)
        self.owner = PortableImageOwner(self.fixture.root)
        self.fixture.trust_query_owner = self.owner
        self.fixture.trust_query_executable = self.owner.path

    def installed_handlers(self):
        """Recover the actual existing main handler, without recreating its body."""
        saved = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        captured = {}

        class CapturedHandler(Exception):
            pass

        def stop(**kwargs):
            captured.update({sig: signal.getsignal(sig) for sig in saved})
            raise CapturedHandler()

        try:
            with (
                mock.patch.object(W, "WireFixture", side_effect=stop),
                mock.patch.object(W.sys, "argv", ["owned-wire-fixture"]),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                with self.assertRaises(CapturedHandler):
                    W.main()
        finally:
            for sig, handler in saved.items():
                signal.signal(sig, handler)
        self.assertEqual(set(captured), set(saved))
        self.assertTrue(all(callable(v) for v in captured.values()))
        return captured

    @contextlib.contextmanager
    def physical_handler(self, signum, handler):
        previous = signal.signal(signum, handler)
        try:
            yield
        finally:
            signal.signal(signum, previous)

    def test01MandatoryOwnerRefusalNeverBecomesUnknownObservation(self):
        primary = B.BuildRefused("Exact mandatory source refusal")
        self.owner.before = mock.Mock(side_effect=primary)
        self.fixture._command = mock.Mock()
        for after in (False, True):
            with self.subTest(after=after), contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaises(B.BuildRefused) as got:
                    self.fixture._observe_admin_trust(time.monotonic() + 2, after=after)
                self.assertIs(got.exception, primary)
                self.assertEqual(output.getvalue(), "")
        self.fixture._command.assert_not_called()

    def test02DifferentOwnedImagePathCannotSelectACallee(self):
        self.owner.verify = lambda: self.owner.path.with_name("foreign-path")
        self.fixture._command = mock.Mock()
        with self.assertRaises(W.FixtureFailure):
            self.fixture._observe_admin_trust(time.monotonic() + 2)
        self.fixture._command.assert_not_called()

    def test03ExactOwnedImageArgumentAndOwnedCertificateDER(self):
        commands = []

        def command(arguments, input_bytes=b"", **kwargs):
            commands.append((arguments, input_bytes, kwargs))
            return (0, json.dumps(RECEIPT).encode())

        self.fixture._command = command
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.fixture._observe_admin_trust(time.monotonic() + 2)
        self.assertEqual(len(commands), 1)
        arguments, der, kwargs = commands[0]
        self.assertEqual(arguments, [str(self.owner.path), "--fixture-admin-trust-query"])
        self.assertEqual(der, ssl.PEM_cert_to_DER_cert(self.fixture.ca.read_text()))
        self.assertLessEqual(kwargs["deadline"], time.monotonic() + 2)
        self.assertEqual(
            json.loads(output.getvalue().removeprefix("# native_http_admin_trust ")),
            {"observed": 1, **RECEIPT},
        )

    def test04OriginalSettledTechnicalFailureRemainsOptionalForEveryRole(self):
        self.fixture._command = mock.Mock(side_effect=RuntimeError("Exact technical query refusal"))
        self.fixture.command_fact = {"phase": "complete", "status": 1}
        for after, after_install, prefix in [
            (False, False, "# native_http_admin_trust "),
            (True, False, "# native_http_admin_trust_after "),
            (False, True, "# native_http_admin_trust_installed "),
        ]:
            output = io.StringIO()
            with (
                self.subTest(after=after, after_install=after_install),
                contextlib.redirect_stdout(output),
                contextlib.redirect_stderr(output),
            ):
                self.fixture._observe_admin_trust(
                    time.monotonic() + 2, after=after, after_install=after_install
                )
            self.assertEqual(
                json.loads(output.getvalue().removeprefix(prefix)), {"version": 1, "observed": 0}
            )

    def test05PhysicalSIGINTAndSIGTERMBeforeNewlyAdmittedQueriesRemainCancellation(self):
        handlers = self.installed_handlers()
        self.fixture._command = mock.Mock()
        for after in (False, True):
            for signum in (signal.SIGINT, signal.SIGTERM):
                self.owner.before = lambda sig=signum: os.kill(os.getpid(), sig)
                output = io.StringIO()
                with (
                    self.subTest(after=after, signum=signum),
                    self.physical_handler(signum, handlers[signum]),
                    contextlib.redirect_stdout(output),
                    contextlib.redirect_stderr(output),
                ):
                    with self.assertRaises(W.FixtureFailure) as got:
                        self.fixture._observe_admin_trust(time.monotonic() + 2, after=after)
                    self.assertEqual(got.exception.args, ("Native fixture cancelled",))
                    self.assertEqual(output.getvalue(), "")
        self.fixture._command.assert_not_called()

    def test06PhysicalSignalsAfterActualPortableQueryRetiresCannotBecomeUnknownSuccess(self):
        handlers = self.installed_handlers()
        original = self.fixture._command
        real_popen = subprocess.Popen
        children = []
        received = []
        body = (
            "import sys,json,hashlib; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(json.dumps("
            + repr(RECEIPT)
            + ").encode())"
        )

        def acquire(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            child.output_capture = kwargs["stdout"]
            child.error_capture = kwargs["stderr"]
            children.append(child)
            return child

        for after in (False, True):
            for signum in (signal.SIGINT, signal.SIGTERM):

                def query(arguments, input_bytes=b"", **kwargs):
                    received.append((arguments, input_bytes))
                    result = original(
                        [sys.executable, "-I", "-B", "-c", body], input_bytes, **kwargs
                    )
                    self.assertEqual(result, (0, json.dumps(RECEIPT).encode()))
                    child = children[-1]
                    self.assertEqual(child.returncode, 0)
                    self.assertTrue(child.stdin.closed)
                    self.assertTrue(child.output_capture.closed)
                    self.assertTrue(child.error_capture.closed)
                    os.kill(os.getpid(), signum)
                    return result

                output = io.StringIO()
                with (
                    self.subTest(after=after, signum=signum),
                    self.physical_handler(signum, handlers[signum]),
                    mock.patch.object(self.fixture, "_command", side_effect=query),
                    mock.patch.object(W.subprocess, "Popen", side_effect=acquire),
                    contextlib.redirect_stdout(output),
                    contextlib.redirect_stderr(output),
                ):
                    with self.assertRaises(W.FixtureFailure) as got:
                        self.fixture._observe_admin_trust(time.monotonic() + 2, after=after)
                    self.assertEqual(got.exception.args, ("Native fixture cancelled",))
                    self.assertEqual(output.getvalue(), "")
        self.assertEqual(len(children), 4)
        for arguments, der in received:
            self.assertEqual(arguments, [str(self.owner.path), "--fixture-admin-trust-query"])
            self.assertEqual(der, ssl.PEM_cert_to_DER_cert(self.fixture.ca.read_text()))

    def test07MandatorySameInodeImageEditRefusesBeforeAnyQuery(self):
        self.owner.path.write_bytes(b"FOREIGN SAME-INODE IMAGE")
        self.fixture._command = mock.Mock()
        with self.assertRaises(B.BuildRefused):
            self.fixture._observe_admin_trust(time.monotonic() + 2)
        self.fixture._command.assert_not_called()

    def test08FixedPACRoleObservationNeverEntersJSONReplyPipe(self):
        self.fixture.trust_query_output = sys.stderr
        self.fixture._command = mock.Mock(return_value=(0, json.dumps(RECEIPT).encode()))
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.fixture.trust_query_output = sys.stderr
            self.fixture._observe_admin_trust(time.monotonic() + 2)
            self.fixture._observe_admin_trust(time.monotonic() + 2, after=True)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(len(stderr.getvalue().splitlines()), 2)


class AliasDuringReadControl(unittest.TestCase):
    def test_owned_read_refuses_real_hardlink_added_after_descriptor_acquisition(self):
        private = tempfile.TemporaryDirectory(prefix="g6-builder-alias-read-")
        root = Path(private.name)
        root.chmod(0o700)
        image = root / "OwnedTestImage"
        alias = root / "SameExactOwnedInodeAlias"
        content = b"ACTUAL PORTABLE IMAGE BYTES; NO SWIFT OR NATIVE CREDIT"
        image.write_bytes(content)
        image.chmod(0o700)
        original = image.stat()
        self.assertEqual(original.st_nlink, 1)
        original_fstat = os.fstat
        observations = []
        record = {
            "qualification": "REAL_POSIX_SAME_INODE_HARDLINK_ONLY_NO_NATIVE_CREDIT",
            "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        }

        def acquire_then_alias(descriptor):
            observed = original_fstat(descriptor)
            observations.append(
                {"device": observed.st_dev, "inode": observed.st_ino, "nlink": observed.st_nlink}
            )
            if len(observations) == 1:
                self.assertEqual(
                    (observed.st_dev, observed.st_ino), (original.st_dev, original.st_ino)
                )
                self.assertEqual(observed.st_nlink, 1)
                os.link(image, alias)
                linked = image.stat()
                self.assertEqual(linked.st_nlink, 2)
                self.assertEqual((linked.st_dev, linked.st_ino), (original.st_dev, original.st_ino))
                self.assertEqual(alias.read_bytes(), content)
            return observed

        try:
            with mock.patch.object(B.os, "fstat", side_effect=acquire_then_alias):
                with self.assertRaisesRegex(B.BuildRefused, "regular|alias|changed|refused"):
                    B.regular_bytes(image)
        finally:
            record.update(
                {
                    "fstat_observations": observations,
                    "actual_same_inode_alias_created": alias.exists(),
                    "nlink_before_outer_cleanup": image.stat().st_nlink,
                    "exact_owned_bytes_unchanged": image.read_bytes() == content,
                }
            )
            private.cleanup()
            record["all_exact_outer_file_names_retired"] = not root.exists()
            RECEIVING.append(record)
            self.assertTrue(record["all_exact_outer_file_names_retired"])


EXPECTED_TEST_IDENTITIES = {
    "BuilderControls": (
        "test01WholeCompilerSourcesAndHeadersStagedExactly",
        "test02SourceEditRefusesBeforeAnyCompilation",
        "test03SourceEditDuringCompilerRefusesSigning",
        "test04SourceEditAfterSigningRefusesQueryQualification",
        "test05StagedRuntimeEditRefuses",
        "test06SameInodeImageEditRefuses",
        "test07SameBytesReplacementImageRefuses",
        "test08ImageSymlinkRefuses",
        "test09ImageHardlinkRefuses",
        "test10ImageParentDirectoryAliasRefuses",
        "test11ReceiptEditRefuses",
        "test12ReceiptSymlinkRefuses",
        "test13CompilerFailureRetainsExactPrimaryAndRootDebt",
        "test14SigningFailureDoesNotBindImage",
        "test15ExactAbsoluteDeadlineSharedByCompileAndSigning",
        "test16ExpiredStartupRefusesBeforeCompilerAndRetainsRoot",
        "test17FixedRoleRejectsArbitrarySelectorsNonfiniteAndRenewedBudgets",
        "test18SourceDirectoryAliasRefuses",
        "test19RootReplacementDoesNotRemoveForeignObject",
        "test20MandatoryOwnerRevalidationFailsBeforeOptionalQuery",
        "test21OwnedQueryCancellationIsNotOptional",
        "test23NativeProcessOwnerMissingRefusesBeforeCompilation",
        "test24ExpiredStartupIsNotRenewedBySigning",
        "test25StartupNeverExtendsExistingSigningCommandCap",
    ),
    "AdmissionControls": (
        "test01MandatoryOwnerRefusalNeverBecomesUnknownObservation",
        "test02DifferentOwnedImagePathCannotSelectACallee",
        "test03ExactOwnedImageArgumentAndOwnedCertificateDER",
        "test04OriginalSettledTechnicalFailureRemainsOptionalForEveryRole",
        "test05PhysicalSIGINTAndSIGTERMBeforeNewlyAdmittedQueriesRemainCancellation",
        "test06PhysicalSignalsAfterActualPortableQueryRetiresCannotBecomeUnknownSuccess",
        "test07MandatorySameInodeImageEditRefusesBeforeAnyQuery",
        "test08FixedPACRoleObservationNeverEntersJSONReplyPipe",
    ),
    "AliasDuringReadControl": (
        "test_owned_read_refuses_real_hardlink_added_after_descriptor_acquisition",
    ),
}


def enrolled_cases():
    """Expose exactly24+8+1 controls; any census/identity drift refuses import."""
    classes = (BuilderControls, AdmissionControls, AliasDuringReadControl)
    for case in classes:
        actual = tuple(unittest.defaultTestLoader.getTestCaseNames(case))
        expected = EXPECTED_TEST_IDENTITIES[case.__name__]
        if case.__module__ != __name__ or actual != expected:
            raise RuntimeError("Portable native fixture control identity refused")
    if sum(len(EXPECTED_TEST_IDENTITIES[case.__name__]) for case in classes) != 33:
        raise RuntimeError("Portable native fixture control census refused")
    return classes
