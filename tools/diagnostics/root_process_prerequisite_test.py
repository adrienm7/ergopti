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


if __name__ == "__main__":
    unittest.main()
