#!/usr/bin/env python3
# tools/test/test_automation_query_ci_publisher.py
"""Portable controlled compiler/signing fixtures; actual macOS build remains CI-only."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
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
            if relative.endswith("run_signed_query_probe.py"):
                shutil.copyfile(ROOT / relative, target)
            else:
                target.write_bytes(("literal input " + relative).encode())
            self.tracked[relative] = target.read_bytes()
        self.compiler = Path(self.temp.name) / "swift"
        self.compiler.write_bytes(b"controlled compiler identity")
        self.directory = self.root / "private-compiler"
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


class CensusFactsTests(unittest.TestCase):
    setUp = PublisherTests.setUp
    command_output = PublisherTests.command_output

    def lock_bytes(self, version=3):
        packet = {
            "pins": [
                {
                    "identity": "sparkle",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/sparkle-project/Sparkle",
                    "state": {"revision": "b" * 40, "version": "2.9.2"},
                }
            ],
            "version": version,
        }
        if version == 3:
            packet["originHash"] = "c" * 64
        return json.dumps(packet, indent=2).encode() + b"\n"

    def untracked_lock(self, raw):
        relative = P.LAUNCHER + "Package.resolved"
        self.inputs.remove(relative)
        del self.tracked[relative]
        path = self.root / relative
        path.write_bytes(raw)
        return path

    def refusal(self):
        P.print.reset_mock()
        with self.assertRaisesRegex(P.Refused, "^native_input_census_mismatch$"):
            P.snapshot(self.root, SHA)
        self.assertEqual(P.print.call_count, 1)
        arguments, options = P.print.call_args
        prefix = "Automation query publisher census refusal facts: "
        self.assertTrue(arguments[0].startswith(prefix))
        self.assertIs(options["file"], P.sys.stderr)
        return json.loads(arguments[0][len(prefix) :])

    def test_exact_public_lock_bytes_report_without_admitting_compiler(self):
        import base64

        raw = self.lock_bytes()
        self.untracked_lock(raw)
        packet = self.refusal()
        self.assertEqual(packet["source_sha"], SHA)
        self.assertEqual(packet["extra_count"], 1)
        self.assertTrue(packet["only_root_lockfile_extra"])
        self.assertFalse(packet["root_lockfile_expected"])
        self.assertTrue(packet["root_lockfile_observed"])
        self.assertEqual(packet["missing_paths"], [])
        lock = packet["lockfile"]
        self.assertEqual(lock["public_sparkle_schema"], 3)
        self.assertEqual(lock["byte_count"], len(raw))
        self.assertEqual(lock["sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(base64.b64decode(lock["validated_public_bytes_base64"]), raw)
        self.assertEqual(self.commands, [])
        self.assertFalse(self.directory.exists())

    def test_both_exact_supported_public_schemas(self):
        for version in (2, 3):
            with self.subTest(version=version):
                self.assertEqual(P.public_sparkle_lock(self.lock_bytes(version)), version)

    def test_unknown_private_fields_never_publish_bytes(self):
        secret = "PRIVATE_TOKEN_SENTINEL"
        raw = self.lock_bytes().replace(
            b'"version": 3', ('"secret": "' + secret + '", "version": 3').encode()
        )
        self.untracked_lock(raw)
        packet = self.refusal()
        self.assertIsNone(packet["lockfile"]["public_sparkle_schema"])
        self.assertNotIn("validated_public_bytes_base64", packet["lockfile"])
        self.assertNotIn(secret, P.print.call_args.args[0])

    def test_duplicate_wrong_repository_pin_and_schema_refuse_payload(self):
        valid = self.lock_bytes()
        variants = [
            valid.replace(b'"version": 3', b'"version": 3, "version": 3'),
            valid.replace(b'Sparkle"', b'PrivateRepo"'),
            valid.replace(b'"version": 3', b'"version": true'),
            valid.replace(b'"2.9.2"', b'"2.9.3"'),
            valid.replace(b'"pins": [', b'"pins": [null,'),
            valid.replace(b"c" * 64, b"x" * 64),
            valid.replace(b"b" * 40, b"x" * 40),
            b"not json",
        ]
        for raw in variants:
            with self.subTest(raw_sha=hashlib.sha256(raw).hexdigest()):
                self.assertIsNone(P.public_sparkle_lock(raw))

    def test_symlink_refuses_capture_without_reading_target(self):
        path = self.untracked_lock(self.lock_bytes())
        target = self.root / "PRIVATE_UNTRACKED_TARGET"
        target.write_bytes(self.lock_bytes())
        path.unlink()
        path.symlink_to(target)
        packet = self.refusal()
        self.assertEqual(packet["lockfile"]["status"], "nonregular")
        self.assertNotIn("sha256", packet["lockfile"])
        self.assertNotIn(str(target), P.print.call_args.args[0])

    def test_current_file_change_refuses_hash_and_payload(self):
        path = self.untracked_lock(self.lock_bytes())
        original = P.os.read
        fired = False

        def change(descriptor, count):
            nonlocal fired
            raw = original(descriptor, count)
            if not fired:
                fired = True
                path.write_bytes(b"X" + path.read_bytes()[1:])
            return raw

        with mock.patch.object(P.os, "read", side_effect=change):
            packet = self.refusal()
        self.assertTrue(fired)
        self.assertEqual(packet["lockfile"]["status"], "changed")
        self.assertNotIn("sha256", packet["lockfile"])
        self.assertNotIn("validated_public_bytes_base64", packet["lockfile"])

    def test_oversized_lock_has_no_read_hash_or_payload(self):
        self.untracked_lock(b"x" * 16385)
        with mock.patch.object(P.os, "read", side_effect=AssertionError("must not read")):
            packet = self.refusal()
        self.assertEqual(packet["lockfile"]["status"], "oversized")
        self.assertEqual(packet["lockfile"]["byte_count"], 16385)
        self.assertNotIn("sha256", packet["lockfile"])

    def test_missing_trusted_path_and_unknown_extra_name(self):
        (self.root / (P.LAUNCHER + "Sources/Main.swift")).unlink()
        extra = self.root / P.LAUNCHER / "PRIVATE_EXTRA_SENTINEL.swift"
        extra.write_bytes(b"private")
        packet = self.refusal()
        self.assertEqual(packet["missing_paths"], [P.LAUNCHER + "Sources/Main.swift"])
        self.assertTrue(packet["missing_paths_complete"])
        self.assertEqual(packet["missing_count"], 1)
        self.assertEqual(packet["extra_count"], 1)
        self.assertNotIn("PRIVATE_EXTRA_SENTINEL", P.print.call_args.args[0])

    def test_successful_snapshot_produces_no_refusal_facts(self):
        P.print.reset_mock()
        self.assertEqual(len(P.snapshot(self.root, SHA)), len(self.inputs) - 2)
        P.print.assert_not_called()

    def test_reporting_failure_keeps_original_strict_refusal(self):
        self.untracked_lock(self.lock_bytes())
        with mock.patch.object(P, "current_lockfile_facts", side_effect=OSError("PRIVATE_FAILURE")):
            with self.assertRaisesRegex(P.Refused, "^native_input_census_mismatch$"):
                P.snapshot(self.root, SHA)
        self.assertEqual(self.commands, [])
        self.assertFalse(self.directory.exists())


if __name__ == "__main__":
    unittest.main()
