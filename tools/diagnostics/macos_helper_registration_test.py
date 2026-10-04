# tools/diagnostics/macos_helper_registration_test.py
"""Validate the native acceptance judge without pretending to run macOS APIs."""

import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import macos_helper_registration as probe

FIXTURE_UID = 501


class NativeBoundary:
    """Retain an exact helper identity and observable launchctl job lifecycle."""

    def __init__(self, executable):
        self.inode = str(executable.stat().st_ino)
        self.present = False
        self.calls = []
        self.initial_status = 113
        self.unregister_stdout = "unregistered\n"
        self.unregister_exit = 0
        self.keep_registered = False
        self.bootout_error = None
        self.final_observation_error = None
        self.print_count = 0

    def run(self, arguments, **options):
        self.calls.append(arguments)
        if arguments[0] == "/bin/launchctl":
            if arguments[2] != f"gui/{FIXTURE_UID}/com.ergoptiplus.remap-guardian":
                raise AssertionError("Unexpected guardian user domain")
            if arguments[1] == "print":
                self.print_count += 1
                if self.print_count == 1:
                    code = self.initial_status
                elif self.final_observation_error and self.print_count > 6:
                    raise self.final_observation_error
                else:
                    code = 0 if self.present else 113
                return subprocess.CompletedProcess(arguments, code, "", "")
            if arguments[1] == "bootout":
                if self.bootout_error:
                    raise self.bootout_error
                self.present = False
                return subprocess.CompletedProcess(arguments, 0, "", "")
            raise AssertionError("Unexpected launchctl operation")
        if options["env"]["ERGOPTI_LAUNCHER_INODE"] != self.inode:
            return subprocess.CompletedProcess(arguments, 64, "", "")
        if arguments[1] == "--register-remap-guardian":
            self.present = True
            return subprocess.CompletedProcess(arguments, 0, "ready\n", "")
        if arguments[1] == "--remap-guardian-status":
            return subprocess.CompletedProcess(arguments, 0, "ready\n", "")
        if arguments[1] == "--unregister-remap-guardian":
            if not self.keep_registered:
                self.present = False
            return subprocess.CompletedProcess(
                arguments, self.unregister_exit, self.unregister_stdout, ""
            )
        raise AssertionError("Unexpected native helper role")


class HelperGuardianAcceptanceTests(unittest.TestCase):
    def run_probe(self, configure=None):
        with TemporaryDirectory() as directory:
            application = Path(directory) / "ErgoptiPlus.app"
            executable = application / "Contents/MacOS/ErgoptiPlus"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"owned helper fixture")
            boundary = NativeBoundary(executable)
            if configure:
                configure(boundary)
            output = Path(directory) / "receipt.json"
            error = None
            with (
                patch.object(probe.sys, "platform", "darwin"),
                patch.object(probe.os, "getuid", return_value=FIXTURE_UID, create=True),
                patch.dict(os.environ, {"RUNNER_ENVIRONMENT": "github-hosted"}),
                patch.object(probe.subprocess, "run", side_effect=boundary.run),
            ):
                try:
                    probe.observe(application, output)
                except RuntimeError as failure:
                    error = str(failure)
            receipt = json.loads(output.read_text())
            return boundary, receipt, error

    def test_qualifies_wrong_identity_retained_job_and_two_exact_unregistrations(self):
        boundary, receipt, error = self.run_probe()
        self.assertIsNone(error)
        self.assertTrue(receipt["unregistration_verified"])
        self.assertEqual(receipt["rejected_unregister"]["exit"], 64)
        self.assertEqual(receipt["job_status_after_rejected_unregister"], 0)
        self.assertEqual(receipt["unregistered"]["stdout"], "unregistered\n")
        self.assertEqual(receipt["repeated_unregister"]["stdout"], "unregistered\n")
        self.assertEqual(receipt["job_status_after_unregister"], 113)
        self.assertEqual(receipt["job_status_after_repeated_unregister"], 113)
        self.assertEqual(receipt["final_job_status"], 113)
        self.assertEqual(receipt["cleanup_errors"], [])
        self.assertFalse(any(call[1] == "bootout" for call in boundary.calls))

    def test_refuses_unknown_initial_status_and_never_changes_an_existing_job(self):
        for status in [0, 1, 5, 64, -9]:
            with self.subTest(status=status):
                boundary, receipt, error = self.run_probe(
                    lambda boundary: setattr(boundary, "initial_status", status)
                )
                self.assertIn("absence was not confirmed before registration", error)
                self.assertEqual(receipt["initial_job_status"], status)
                self.assertTrue(
                    all(call[:2] == ["/bin/launchctl", "print"] for call in boundary.calls)
                )

    def test_requires_exact_receipt_and_zero_exit_even_when_the_job_disappears(self):
        for stdout, code in [
            ("unregistered", 0),
            ("unregistered\nready\n", 0),
            ("refused\n", 0),
            ("unregistered\n", 1),
        ]:
            with self.subTest(stdout=stdout, code=code):

                def configure(boundary):
                    boundary.unregister_stdout = stdout
                    boundary.unregister_exit = code

                _, receipt, error = self.run_probe(configure)
                self.assertIn("did not acknowledge guardian removal", error)
                self.assertNotIn("unregistration_verified", receipt)
                self.assertTrue(receipt["job_absent_after_cleanup"])

    def test_receipt_alone_cannot_prove_absence_and_cleanup_keeps_the_primary_failure(self):
        def configure(boundary):
            boundary.keep_registered = True

        boundary, receipt, error = self.run_probe(configure)
        self.assertIn("did not prove exact job absence", error)
        self.assertTrue(receipt["job_absent_after_cleanup"])
        self.assertTrue(any(call[1] == "bootout" for call in boundary.calls))

    def test_primary_unregister_refusal_and_cleanup_timeout_are_both_written(self):
        def configure(boundary):
            boundary.keep_registered = True
            boundary.unregister_stdout = "refused\n"
            boundary.bootout_error = subprocess.TimeoutExpired("owned bootout", 10)

        _, receipt, error = self.run_probe(configure)
        self.assertIn("did not acknowledge guardian removal", receipt["primary_error"])
        self.assertTrue(any("timed out" in item for item in receipt["cleanup_errors"]))
        self.assertIn(receipt["primary_error"], error)
        self.assertIn("timed out", error)
        self.assertFalse(receipt["job_absent_after_cleanup"])

    def test_final_observation_timeout_is_written_and_cannot_qualify_cleanup(self):
        def configure(boundary):
            boundary.final_observation_error = subprocess.TimeoutExpired("owned observation", 10)

        _, receipt, error = self.run_probe(configure)
        self.assertIn("Final guardian observation failed", error)
        self.assertFalse(receipt["job_absent_after_cleanup"])
        self.assertTrue(any("timed out" in item for item in receipt["cleanup_errors"]))


if __name__ == "__main__":
    unittest.main()
