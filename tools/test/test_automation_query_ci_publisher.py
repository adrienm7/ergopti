#!/usr/bin/env python3
# tools/test/test_automation_query_ci_publisher.py
"""Portable controlled compiler/signing fixtures; actual macOS build remains CI-only."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import types
import subprocess
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "publisher", ROOT / "tools/build/automation_query_ci_publisher.py"
)
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
SHA = "a" * 40


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "root"
        self.root.mkdir()
        native = [
            "Package.swift",
            "Package.resolved",
            "Sources/Main.swift",
            "Sources/Owned.c",
            "Sources/include/Owned.h",
            "Tests/WorkerTests.swift",
        ]
        self.inputs = [P.LAUNCHER + path for path in native]
        self.inputs += [
            "tools/diagnostics/program_actions/run_signed_query_probe.py",
            "tools/diagnostics/program_actions/permission_observation.py",
            "tools/diagnostics/program_actions/test_permission_observation.py",
            "tools/diagnostics/macos_owned_process.py",
            "static/ergopti_plus/macos/adapters/apple_shortcuts.lua",
            "static/ergopti_plus/macos/adapters/apple_shortcuts_native.lua",
            "tools/build/automation_query_ci_publisher.py",
            "tools/build/build_macos_app.sh",
        ]
        self.tracked = {}
        for relative in self.inputs:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if relative.endswith(
                (
                    "run_signed_query_probe.py",
                    "permission_observation.py",
                    "test_permission_observation.py",
                )
            ):
                shutil.copyfile(ROOT / relative, target)
            else:
                target.write_bytes(("literal input " + relative).encode())
            self.tracked[relative] = target.read_bytes()
        self.compiler = Path(self.temp.name) / "swift"
        self.compiler.write_bytes(b"controlled compiler identity")
        self.directory = self.root / "private-compiler"
        self.native_stat = Path.stat
        self.custody_mode = 0o700
        if os.name == "nt":
            # This controlled POSIX metadata is not a Windows ACL observation.
            # Only the fixture's exact directory receives it; files and links
            # retain their real native facts and all production checks remain.
            def directory_stat(candidate, *arguments, **options):
                facts = self.native_stat(candidate, *arguments, **options)
                if candidate == self.directory and stat.S_ISDIR(facts.st_mode):
                    return os.stat_result(
                        ((facts.st_mode & ~0o777) | self.custody_mode, *facts[1:])
                    )
                return facts

            metadata = mock.patch.object(Path, "stat", autospec=True, side_effect=directory_stat)
            metadata.start()
            self.addCleanup(metadata.stop)
        self.app = self.root / "Bound.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.helper = self.app / "Contents/MacOS/ErgoptiAutomationQuery"
        self.commands = []
        self.env = mock.patch.dict(
            os.environ,
            {
                "GITHUB_ACTIONS": "true",
                "GITHUB_SHA": SHA,
                "GITHUB_RUN_ID": "17",
                "GITHUB_RUN_ATTEMPT": "2",
            },
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        self.outputs = mock.patch.object(
            P.subprocess, "check_output", side_effect=self.command_output
        )
        self.outputs.start()
        self.addCleanup(self.outputs.stop)
        self.platform = mock.patch.object(P.sys, "platform", "darwin")
        self.platform.start()
        self.addCleanup(self.platform.stop)
        self.version = mock.patch.object(P.sys, "version_info", (3, 13))
        self.version.start()
        self.addCleanup(self.version.stop)
        self.verify = mock.patch.object(P.subprocess, "run", return_value=mock.Mock(returncode=0))
        self.verifier = self.verify.start()
        self.addCleanup(self.verify.stop)
        printing = mock.patch.object(P, "print", create=True)
        printing.start()
        self.addCleanup(printing.stop)

    def command_output(self, arguments, **options):
        if arguments[:3] == ["git", "rev-parse", "HEAD"]:
            return (SHA + "\n").encode()
        if arguments[:2] == ["git", "ls-tree"]:
            return (
                "\n".join(path for path in self.inputs if path.startswith(P.LAUNCHER)) + "\n"
            ).encode()
        if arguments[:2] == ["git", "show"]:
            return self.tracked[arguments[2].split(":", 1)[1]]
        if arguments[:2] == ["/usr/bin/xcrun", "--find"]:
            return (str(self.compiler) + "\n").encode()
        if arguments[:2] == ["/usr/bin/lipo", "-archs"]:
            return b"arm64 x86_64\n"
        self.fail("unexpected source/compiler command " + str(arguments))

    def compiler_run(self, root, arguments, output, timeout=600):
        self.commands.append(arguments)
        self.assertEqual(arguments[:2], [str(self.compiler), "build"])
        self.assertEqual(arguments[2:8], ["-c", "release", "--arch", "arm64", "--arch", "x86_64"])
        package = Path(arguments[arguments.index("--package-path") + 1])
        self.assertEqual(package, self.directory / "package")
        self.assertIn("--disable-automatic-resolution", arguments)
        product_dir = package / ".build/universal/release"
        product_dir.mkdir(parents=True, exist_ok=True)
        if "--product" in arguments:
            (product_dir / "ErgoptiPlus").write_bytes(b"actual controlled compiler output")
        else:
            output.write((str(product_dir) + "\n").encode())

    def built(self):
        P.compile_product(self.root, self.directory, self.compiler_run)
        packet = json.loads((self.directory / P.STATE).read_bytes())
        shutil.copyfile(packet["product"], self.helper)
        P.copied(self.root, self.directory, self.app)
        # A signing fixture changes the copied product; seal must hash these bytes.
        self.helper.write_bytes(self.helper.read_bytes() + b" controlled nested signature")
        return packet

    def test_real_pipeline_binds_actual_compiler_product_final_signature_and_outer_seal(self):
        proof = self.built()
        P.seal(self.root, self.directory, self.app)
        receipt = json.loads(
            (self.app / "Contents/Resources/automation-query-build.json").read_bytes()
        )
        self.assertEqual(
            receipt["helper_sha256"], hashlib.sha256(self.helper.read_bytes()).hexdigest()
        )
        self.assertNotEqual(receipt["helper_sha256"], proof["unsigned_sha256"])
        self.assertEqual(
            set(proof["native_hashes"]),
            {path[len(P.LAUNCHER) :] for path in self.inputs if path.startswith(P.LAUNCHER)},
        )
        self.assertEqual(len(self.commands), 2)
        P.verify_outer(self.root, self.directory, self.app)
        self.assertTrue((self.directory / "outer-verified.json").is_file())
        self.assertEqual(self.verifier.call_args.args[0][-1], str(self.app))

    def test_counterfeit_tracked_source_refused_before_compiler(self):
        (self.root / self.inputs[2]).write_bytes(b"counterfeit native source")
        with self.assertRaisesRegex(P.Refused, "tracked_input_mismatch"):
            P.compile_product(self.root, self.directory, self.compiler_run)
        self.assertEqual(self.commands, [])

    def test_extra_untracked_native_input_refused(self):
        (self.root / P.LAUNCHER / "Sources/Foreign.swift").write_bytes(b"foreign")
        with self.assertRaisesRegex(P.Refused, "native_input_census_mismatch"):
            P.compile_product(self.root, self.directory, self.compiler_run)

    def test_omitted_tracked_header_refused(self):
        (self.root / self.inputs[4]).unlink()
        with self.assertRaisesRegex(P.Refused, "native_input_census_mismatch"):
            P.compile_product(self.root, self.directory, self.compiler_run)

    def test_counterfeit_observer_refused_before_import(self):
        (self.root / "tools/diagnostics/program_actions/run_signed_query_probe.py").write_bytes(
            b'raise Exception("must never execute")'
        )
        with self.assertRaisesRegex(P.Refused, "observer_source_mismatch"):
            P.compile_product(self.root, self.directory, self.compiler_run)

    def test_compiler_failure_has_no_receipt_or_product_admission(self):
        def fail(*arguments):
            raise P.Refused("compiler_failed")

        with self.assertRaisesRegex(P.Refused, "compiler_failed"):
            P.compile_product(self.root, self.directory, fail)
        self.assertFalse((self.directory / P.STATE).exists())

    def test_no_cached_compiler_product_accepted(self):
        self.directory.mkdir(mode=0o700)
        with self.assertRaises(FileExistsError):
            P.compile_product(self.root, self.directory, self.compiler_run)
        self.assertEqual(self.commands, [])

    def test_counterfeit_copied_helper_refused(self):
        P.compile_product(self.root, self.directory, self.compiler_run)
        self.helper.write_bytes(b"foreign cached helper")
        with self.assertRaisesRegex(P.Refused, "copied_product_mismatch"):
            P.copied(self.root, self.directory, self.app)

    def test_omitted_compiler_census_in_state_refused(self):
        self.built()
        proof = json.loads((self.directory / P.STATE).read_bytes())
        del proof["native_hashes"]["Sources/include/Owned.h"]
        (self.directory / P.STATE).write_text(json.dumps(proof))
        with self.assertRaisesRegex(P.Refused, "compiler_input_census_omitted"):
            P.seal(self.root, self.directory, self.app)

    def test_extra_staged_compiler_source_refused(self):
        self.built()
        (self.directory / "package/Sources/Foreign.swift").write_bytes(
            b"unrecorded compiler source"
        )
        with self.assertRaisesRegex(P.Refused, "staged_census_changed"):
            P.seal(self.root, self.directory, self.app)

    def test_changed_compiler_input_after_build_refused(self):
        self.built()
        (self.directory / "package/Sources/Main.swift").write_bytes(b"changed after compile")
        with self.assertRaisesRegex(P.Refused, "compiler_input_changed"):
            P.seal(self.root, self.directory, self.app)

    def test_changed_unsigned_product_after_build_refused(self):
        proof = self.built()
        Path(proof["product"]).write_bytes(b"foreign postcompile product")
        with self.assertRaisesRegex(P.Refused, "compiler_product_changed"):
            P.seal(self.root, self.directory, self.app)

    def test_outer_sign_helper_change_refuses_without_rewriting_receipt(self):
        self.built()
        P.seal(self.root, self.directory, self.app)
        receipt = self.app / "Contents/Resources/automation-query-build.json"
        before = receipt.read_bytes()
        self.helper.write_bytes(b"rewritten by outer signing")
        with self.assertRaisesRegex(P.Refused, "outer_sign_changed_helper"):
            P.verify_outer(self.root, self.directory, self.app)
        self.assertEqual(receipt.read_bytes(), before)
        self.assertFalse((self.directory / "outer-verified.json").exists())

    def test_outer_resource_change_refused(self):
        self.built()
        P.seal(self.root, self.directory, self.app)
        (self.app / "Contents/Resources/automation-query-build.json").write_bytes(
            b"foreign receipt"
        )
        with self.assertRaisesRegex(P.Refused, "outer_sign_changed_receipt"):
            P.verify_outer(self.root, self.directory, self.app)

    def test_actual_ci_identity_required(self):
        with mock.patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}):
            with self.assertRaisesRegex(P.Refused, "head_mismatch"):
                P.compile_product(self.root, self.directory, self.compiler_run)
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}):
            with self.assertRaisesRegex(P.Refused, "not_hosted_ci"):
                P.compile_product(self.root, self.directory, self.compiler_run)

    def test_incorrect_directory_mode_remains_exactly_refused(self):
        P.compile_product(self.root, self.directory, self.compiler_run)
        before = (self.directory / P.STATE).read_bytes()
        if os.name == "nt":
            self.custody_mode = 0o755
        else:
            self.directory.chmod(0o755)
        with self.assertRaisesRegex(P.Refused, "^state_custody$"):
            P.copied(self.root, self.directory, self.app)
        self.assertEqual((self.directory / P.STATE).read_bytes(), before)
        self.assertFalse((self.directory / "copied.json").exists())

    def test_directory_metadata_port_preserves_every_other_native_path(self):
        P.compile_product(self.root, self.directory, self.compiler_run)
        facts = self.native_stat(self.directory)
        observed = self.directory.stat()
        self.assertEqual(observed.st_mode & 0o777, 0o700)
        self.assertEqual(stat.S_IFMT(observed.st_mode), stat.S_IFMT(facts.st_mode))
        for field in ("st_ino", "st_dev", "st_nlink", "st_uid", "st_gid", "st_size"):
            self.assertEqual(getattr(observed, field), getattr(facts, field))
        product = Path(json.loads((self.directory / P.STATE).read_bytes())["product"])
        for target in (self.root, self.compiler, product, self.root / self.inputs[2]):
            self.assertEqual(target.stat(), self.native_stat(target))
        if os.name == "nt":
            link_facts = os.stat_result((stat.S_IFLNK | 0o777, *facts[1:]))
            with mock.patch.object(self, "native_stat", return_value=link_facts):
                self.assertEqual(self.directory.lstat().st_mode, link_facts.st_mode)


class CompilerCustodyTests(unittest.TestCase):
    """Controlled native owner faults; never infer macOS retirement from these."""

    def setUp(self):
        self.addCleanup(P._RETAINED_COMPILERS.clear)
        self.group = types.SimpleNamespace(
            reservation_lost=False,
            reap_started=False,
            reaped=False,
            process=types.SimpleNamespace(returncode=None),
            calls=0,
        )

        def timeout(_deadline):
            raise subprocess.TimeoutExpired("controlled compiler", 1)

        self.group.wait_for_exit = timeout

        def acquire(_arguments, _native, register, **_options):
            register(self.group)

        owner = types.SimpleNamespace(NativeProcessGroups=lambda: object(), acquire_owned=acquire)
        self.port = mock.patch.object(P, "load_module", return_value=owner)
        self.port.start()
        self.addCleanup(self.port.stop)
        signals = mock.patch.object(P.signal, "signal", return_value=P.signal.SIG_DFL)
        signals.start()
        self.addCleanup(signals.stop)

    def test_business_failure_waits_for_exact_closure_before_rethrow(self):
        sleeps = []

        def settle():
            self.group.calls += 1
            if self.group.calls == 1:
                return False
            self.group.reap_started = True
            self.group.reaped = True
            self.group.process.returncode = 0
            return True

        self.group.settle = settle

        def pause(_duration):
            self.assertIs(P._RETAINED_COMPILERS[id(self.group)], self.group)
            self.assertFalse(self.group.reaped)
            sleeps.append(True)

        with mock.patch.object(P.time, "sleep", side_effect=pause):
            with self.assertRaises(subprocess.TimeoutExpired):
                P.native_run(Path("controlled"), ["fixed-compiler"], None, 1)
        self.assertEqual(self.group.calls, 2)
        self.assertEqual(sleeps, [True])
        self.assertNotIn(id(self.group), P._RETAINED_COMPILERS)

    def test_lost_reservation_retains_owner_without_another_settle_or_signal(self):
        class ControlledParkCheckpoint(BaseException):
            pass

        def timeout(_deadline):
            self.group.reservation_lost = True
            raise RuntimeError("controlled lost observation")

        self.group.wait_for_exit = timeout

        def forbidden_settle():
            self.group.calls += 1
            self.fail("lost reservation cannot authorize settlement signals")

        self.group.settle = forbidden_settle

        def park(_duration):
            self.assertIs(P._RETAINED_COMPILERS[id(self.group)], self.group)
            raise ControlledParkCheckpoint()

        with mock.patch.object(P.time, "sleep", side_effect=park):
            with self.assertRaises(ControlledParkCheckpoint):
                P.native_run(Path("controlled"), ["fixed-compiler"], None, 1)
        self.assertIs(P._RETAINED_COMPILERS[id(self.group)], self.group)
        self.assertFalse(self.group.reaped)
        self.assertEqual(self.group.calls, 0)

    def test_settlement_exception_retains_owner_and_never_retries_after_loss(self):
        class ControlledParkCheckpoint(BaseException):
            pass

        def settle():
            self.group.calls += 1
            self.group.reservation_lost = True
            raise RuntimeError("controlled native settlement lost reservation")

        self.group.settle = settle

        pauses = []

        def park(_duration):
            self.assertIs(P._RETAINED_COMPILERS[id(self.group)], self.group)
            pauses.append(True)
            if len(pauses) == 2:
                raise ControlledParkCheckpoint()

        with mock.patch.object(P.time, "sleep", side_effect=park):
            with self.assertRaises(ControlledParkCheckpoint):
                P.native_run(Path("controlled"), ["fixed-compiler"], None, 1)
        self.assertEqual(self.group.calls, 1)
        self.assertIs(P._RETAINED_COMPILERS[id(self.group)], self.group)


class PermissionPublisherEnrollmentTests(unittest.TestCase):
    setUp = PublisherTests.setUp
    command_output = PublisherTests.command_output
    compiler_run = PublisherTests.compiler_run
    built = PublisherTests.built

    def test_decoder_and_controls_are_sealed_in_original_receipt(self):
        self.built()
        P.seal(self.root, self.directory, self.app)
        receipt = json.loads(
            (self.app / "Contents/Resources/automation-query-build.json").read_bytes()
        )
        for relative in (
            "tools/diagnostics/program_actions/permission_observation.py",
            "tools/diagnostics/program_actions/test_permission_observation.py",
        ):
            self.assertEqual(
                receipt["source_hashes"][relative],
                hashlib.sha256(self.tracked[relative]).hexdigest(),
            )
        self.assertEqual(
            set(receipt),
            {
                "schema",
                "contract",
                "source_sha",
                "source_hashes",
                "helper_sha256",
                "ci_run_id",
                "ci_run_attempt",
            },
        )

    def test_decoder_counterfeit_refused_before_compiler(self):
        relative = "tools/diagnostics/program_actions/permission_observation.py"
        (self.root / relative).write_bytes(b'raise RuntimeError("must not execute")')
        with self.assertRaisesRegex(P.Refused, "tracked_input_mismatch"):
            P.compile_product(self.root, self.directory, self.compiler_run)
        self.assertEqual(self.commands, [])

    def test_decoder_omission_refused_before_compiler(self):
        relative = "tools/diagnostics/program_actions/permission_observation.py"
        del self.tracked[relative]
        with self.assertRaises(KeyError):
            P.compile_product(self.root, self.directory, self.compiler_run)
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
