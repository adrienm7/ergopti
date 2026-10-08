# tools/diagnostics/root_process_prerequisite_test.py
"""Frozen closed-interface controls; these do not model privileged native ownership."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).with_name("root_process_prerequisite.py")
specification = importlib.util.spec_from_file_location("root_prerequisite_subject", SOURCE)
subject = importlib.util.module_from_spec(specification)
specification.loader.exec_module(subject)


class ClosedControls(unittest.TestCase):
    def test_root_locator_accepts_only_owned_closed_namespace(self):
        accepted = "/private/var/tmp/ergopti-root-process-" + "a" * 32
        self.assertEqual(subject.root_locator(accepted), Path(accepted))
        for value in (
            "relative",
            accepted + "/probe",
            accepted + "/../other",
            accepted.replace("a" * 32, "A" * 32),
            accepted + "\n",
        ):
            with self.assertRaises(subject.Refusal):
                subject.root_locator(value)

    def test_digest_shape_rejects_reflected_or_truncated_values(self):
        self.assertEqual(subject.digest("a" * 64), "a" * 64)
        for value in ("", "a" * 63, "a" * 65, "A" * 64, "a" * 64 + "\n", 0):
            with self.assertRaises(subject.Refusal):
                subject.digest(value)

    def test_closed_protocol_has_no_path_or_credential_fields(self):
        expected = (
            (b"V1 HELD 17\n", "V1 HELD 17"),
            (b"V1 CHILD 23\n", "V1 CHILD 23"),
            (b"V1 CHILD_RETIRED\n", "V1 CHILD_RETIRED"),
            (b"V1 RETIRED\n", "V1 RETIRED"),
            (b"V1 DEBT\n", "V1 DEBT"),
        )
        for value, rendered in expected:
            self.assertEqual(subject.closed_line(value), rendered)
        for value in (
            b"V1 HELD 0\n",
            b"V1 HELD -1\n",
            b"V1 HELD 17",
            b"V1 HELD 17\nV1 RETIRED\n",
            b"V1 RETIRED /private/keychain\n",
            b"\xff\n",
            b"x" * 65 + b"\n",
        ):
            with self.assertRaises(subject.Refusal):
                subject.closed_line(value)

    def test_missing_native_platform_refuses_before_privileged_acquisition(self):
        with patch.object(subject.sys, "platform", "linux"), patch.object(subject, "Held") as held:
            with self.assertRaises(subject.Refusal) as raised:
                subject.run("/not-read", "/not-read")
            self.assertEqual(raised.exception.code, "native_ordinary_caller")
            held.assert_not_called()

    def test_root_caller_refuses_before_input_or_sudo(self):
        with (
            patch.object(subject.sys, "platform", "darwin"),
            patch.object(subject.os, "geteuid", return_value=0),
            patch.object(subject, "Held") as held,
        ):
            with self.assertRaises(subject.Refusal):
                subject.run("/not-read", "/not-read")
            held.assert_not_called()

    def test_retained_debt_keeps_the_actual_object(self):
        owner = object()
        refusal = subject.Refusal("bootstrap_group_debt", [owner])
        self.assertIs(refusal.owners[0], owner)
        self.assertEqual(refusal.code, "bootstrap_group_debt")

    def test_ordinary_file_currentness_detects_same_size_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "input"
            path.write_bytes(b"ordinary")
            held = subject.Held(path)
            try:
                path.unlink()
                path.write_bytes(b"ordinary")
                with self.assertRaises(subject.Refusal):
                    held.current()
            finally:
                held.close()

    def test_c_parser_refuses_malformed_roles_without_native_fallback(self):
        compiler = "/usr/bin/gcc-14"
        if not Path(compiler).exists():
            self.skipTest("Linux portable compiler prerequisite unavailable")
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "probe"
            subprocess.run(
                [
                    compiler,
                    "-std=c17",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(SOURCE.with_suffix(".c")),
                    "-o",
                    str(executable),
                ],
                check=True,
                capture_output=True,
            )
            invalid = (
                [],
                ["--other"],
                ["--probe", "a" * 64],
                ["--probe", "a" * 64, "0"],
                ["--probe", "A" * 64, "1"],
                ["--probe", "a" * 64, "-1"],
                ["--probe", "a" * 64, "1", "extra"],
            )
            for arguments in invalid:
                result = subprocess.run([str(executable)] + arguments, capture_output=True)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (64, b"", b""))
            supported_shape = subprocess.run(
                [str(executable), "--probe", "a" * 64, "1"], capture_output=True
            )
            self.assertEqual(supported_shape.returncode, 69)
            self.assertEqual(
                supported_shape.stderr, b"UNAVAILABLE: Darwin root process prerequisite\n"
            )
            self.assertEqual(supported_shape.stdout, b"")


class FailureDiagnosticControls(unittest.TestCase):
    """Portable actual-entrypoint controls; no SDK/root ownership is modeled as admitted."""

    def invoke(self, body, *, direct=False):
        import sys

        if direct:
            arguments = [
                sys.executable,
                str(SOURCE),
                "/inert/repository",
                "/inert/output",
            ]
        else:
            script = (
                "import importlib.util,sys\n"
                "spec=importlib.util.spec_from_file_location('root_boundary_subject',sys.argv[1])\n"
                "subject=importlib.util.module_from_spec(spec);spec.loader.exec_module(subject)\n"
                "sys.argv=[sys.argv[1],'/inert/repository','/inert/output']\n"
                + body
                + "\nraise SystemExit(subject.main())\n"
            )
            arguments = [sys.executable, "-c", script, str(SOURCE)]
        result = subprocess.run(arguments, capture_output=True, timeout=10)
        receipt = {
            "status": result.returncode,
            "stdout": result.stdout.decode(),
            "stderr": result.stderr.decode(),
        }
        self.__class__.receipts.append(receipt)
        return result

    @classmethod
    def setUpClass(cls):
        cls.receipts = []

    @classmethod
    def tearDownClass(cls):
        import json
        import os

        target = os.environ.get("ERGOPTI_ROOT_DIAGNOSTIC_RECEIPT")
        if target:
            Path(target).write_text(json.dumps(cls.receipts, indent=2) + "\n")

    def refusal(self, result, reason):
        import json

        self.assertEqual(result.returncode, 69)
        self.assertEqual(result.stdout, b"")
        lines = result.stderr.splitlines()
        self.assertEqual(len(lines), 2, "the original failure prefix needs one bounded diagnostic")
        self.assertEqual(lines[0], b"UNAVAILABLE: root process prerequisite")
        prefix = b"ERGOPTI_ROOT_PREREQUISITE_DIAGNOSTIC "
        self.assertTrue(lines[1].startswith(prefix))
        self.assertLessEqual(len(lines[1]), 256)
        self.assertEqual(
            json.loads(lines[1][len(prefix) :]),
            {
                "schema": 1,
                "kind": "root_process_prerequisite_refusal_observation",
                "stage": "prerequisite",
                "reason": reason,
                "authority": False,
                "native_verdict": "unchanged",
            },
        )

    def test_actual_non_darwin_cli_retains_unavailable_primary_verdict(self):
        import sys

        if sys.platform == "darwin":
            self.skipTest("the actual macOS root policy is outside portable boundary controls")
        self.refusal(self.invoke("", direct=True), "native_ordinary_caller")

    def test_literal_refusal_names_are_observed_without_phase_inference(self):
        for reason in (
            "native_ordinary_caller",
            "published_ordinary_owner_pin",
            "preflight_oracle_source_pin",
            "preflight_tool_path",
            "preflight_sdk_role",
            "preflight_apple_tool",
            "preflight_owned_child_refused",
            "root_bootstrap_not_qualified",
        ):
            body = (
                "def failing(*args):\n subject.require(False,"
                + repr(reason)
                + ")\nsubject.run=failing"
            )
            self.refusal(self.invoke(body), reason)

    def test_unknown_and_nonscalar_refusal_codes_never_disclose_user_data(self):
        for expression in (
            "'PRIVATE_USER_SECRET_/Users/secret\\n::error::injected'",
            "'PRIVATE_'*1024",
            "['PRIVATE_USER_SECRET']",
            "{'PRIVATE_USER_SECRET':1}",
            "None",
        ):
            result = self.invoke(
                "def failing(*args):\n raise subject.Refusal("
                + expression
                + ")\nsubject.run=failing"
            )
            self.refusal(result, "unclassified")
            self.assertNotIn(b"PRIVATE_", result.stderr)
            self.assertNotIn(b"/Users", result.stderr)

    def test_oserror_has_a_closed_name_without_message_path_or_errno_disclosure(self):
        for expression in (
            "PermissionError(13,'PRIVATE_USER_SECRET','/Users/private')",
            "OSError(2,'PRIVATE_USER_SECRET','/Users/private')",
        ):
            result = self.invoke(
                "def failing(*args):\n raise " + expression + "\nsubject.run=failing"
            )
            self.refusal(result, "os_error")
            self.assertNotIn(b"PRIVATE_USER_SECRET", result.stderr)
            self.assertNotIn(b"/Users", result.stderr)

    def test_subprocess_failure_never_reflects_command_output_or_timeout(self):
        for expression in (
            "subject.subprocess.CalledProcessError(12,['/Users/PRIVATE_COMMAND'],output=b'PRIVATE_STDOUT',stderr=b'PRIVATE_STDERR')",
            "subject.subprocess.TimeoutExpired(['/Users/PRIVATE_COMMAND'],1,output=b'PRIVATE_STDOUT',stderr=b'PRIVATE_STDERR')",
        ):
            result = self.invoke(
                "def failing(*args):\n raise " + expression + "\nsubject.run=failing"
            )
            self.refusal(result, "subprocess_error")
            self.assertNotIn(b"PRIVATE_", result.stderr)
            self.assertNotIn(b"/Users", result.stderr)

    def test_foreign_refusal_subclass_does_not_supply_diagnostic_authority(self):
        result = self.invoke(
            "class ForeignRefusal(subject.Refusal):\n pass\ndef failing(*args):\n raise ForeignRefusal('PRIVATE_USER_SECRET')\nsubject.run=failing"
        )
        self.refusal(result, "unclassified")
        self.assertNotIn(b"PRIVATE_USER_SECRET", result.stderr)

    def test_successful_entrypoint_is_unchanged_and_has_no_failure_diagnostic(self):
        import json

        result = self.invoke(
            "subject.run=lambda *args:{'schema':1,'boundary_control':'ordinary_only'}"
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(
            json.loads(result.stdout),
            {"schema": 1, "boundary_control": "ordinary_only"},
        )

    def test_diagnostic_writer_refusal_keeps_existing_prefix_and_primary_69(self):
        result = self.invoke(
            "class FailureSink:\n def write(self,value):\n  if value.startswith('ERGOPTI_ROOT_PREREQUISITE_DIAGNOSTIC '):\n   raise OSError('PRIVATE_SINK_FAILURE')\n  return original.write(value)\n def flush(self):\n  return original.flush()\noriginal=sys.stderr;sys.stderr=FailureSink()\ndef failing(*args):\n raise subject.Refusal('preflight_sdk_role')\nsubject.run=failing"
        )
        self.assertEqual(result.returncode, 69)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"UNAVAILABLE: root process prerequisite\n")

    def test_diagnostic_keeps_actual_refusal_owners_without_calling_foreign_formatters(
        self,
    ):
        body = "class Owner:\n def __repr__(self):\n  raise RuntimeError('PRIVATE_OWNER_CALLBACK')\nowner=Owner()\ndef failing(*args):\n raise subject.Refusal('preflight_sdk_role',[owner])\nsubject.run=failing"
        result = self.invoke(body)
        self.refusal(result, "preflight_sdk_role")
        self.assertNotIn(b"PRIVATE_OWNER_CALLBACK", result.stderr)

    def test_apple_tool_refusals_name_role_and_dimension_before_open(self):
        import stat
        from types import SimpleNamespace

        paths = {
            "compiler": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            "sdk": "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk",
        }
        for role, path in paths.items():
            mode = (stat.S_IFREG if role == "compiler" else stat.S_IFDIR) | 0o755
            for dimension, uid, observed_mode in (
                ("owner", 501, mode),
                ("writable", 0, mode | stat.S_IWGRP),
                ("kind", 0, (stat.S_IFDIR if role == "compiler" else stat.S_IFREG) | 0o755),
            ):
                with self.subTest(role=role, dimension=dimension):
                    named = SimpleNamespace(st_uid=uid, st_mode=observed_mode)
                    with (
                        patch.object(subject.Path, "resolve", lambda value, **unused: value),
                        patch.object(subject.Path, "lstat", return_value=named),
                        patch.object(subject.os, "open") as opened,
                    ):
                        with self.assertRaises(subject.Refusal) as raised:
                            subject.PreflightTool(path, role)
                        self.assertEqual(raised.exception.code, f"preflight_{role}_{dimension}")
                        self.assertEqual(raised.exception.owners, ())
                        opened.assert_not_called()

    def test_closed_apple_tool_reason_names_preserve_primary_verdict(self):
        for role in ("compiler", "sdk"):
            for dimension in ("owner", "writable", "kind"):
                reason = f"preflight_{role}_{dimension}"
                body = (
                    "def failing(*args):\n subject.require(False,"
                    + repr(reason)
                    + ")\nsubject.run=failing"
                )
                self.refusal(self.invoke(body), reason)


if __name__ == "__main__":
    unittest.main()
