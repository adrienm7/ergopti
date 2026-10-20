"""Portable controls for isolated native receiving; these never execute Swift."""

import hashlib
import importlib
import json
import os
import shutil
import sys
import textwrap
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, call, patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/diagnostics"))
try:
    isolation = importlib.import_module("input_source_xctest_isolation")
finally:
    sys.path.pop(0)

CLASS = "InputSourceSelectionWorkerTests"
METHOD = "testNativeStatusesAndMissingSourceRemainDistinct"
SOURCE = f"func {METHOD}() {{}}\nfunc testOther() {{}}\n"


def transcript(method=METHOD, status="passed", style="swift"):
    identity = (
        f"ErgoptiPlusTests.{CLASS}.{method}"
        if style == "swift"
        else f"-[ErgoptiPlusTests.{CLASS} {method}]"
    )
    return (
        "Test Suite 'Selected tests' started at time\n"
        f"Test Case '{identity}' started.\n"
        f"Test Case '{identity}' {status} (0.001 seconds).\n"
        "Test Suite 'Selected tests' passed at time\n"
    )


# The isolation runner retires each child through its POSIX process group.
POSIX_GROUPS = unittest.skipUnless(
    hasattr(os, "killpg"),
    "not executed: needs POSIX process groups (os.killpg); hosted CI lanes execute it",
)


class IsolationControls(unittest.TestCase):
    def evaluate(self, log, test=0, capture=0):
        return isolation.selected_receipt(SOURCE, log, CLASS, METHOD, test, capture)

    def test_real_file_hash_is_distinct_from_selection_metadata(self):
        for style in ("swift", "objc"):
            result = self.evaluate(transcript(style=style))
            self.assertTrue(result["passed"])
            self.assertEqual(result["expected_count"], 1)
            self.assertEqual(result["received_count"], 1)
            self.assertEqual(result["source_sha"], hashlib.sha256(SOURCE.encode()).hexdigest())
            self.assertNotEqual(result["source_sha"], result["selection_metadata_sha"])

    def test_zero_matching_tests_cannot_pass(self):
        self.assertFalse(self.evaluate("warning: No matching test cases were run")["passed"])

    def test_another_method_cannot_satisfy_the_selected_method(self):
        self.assertFalse(self.evaluate(transcript(method="testOther"))["passed"])

    def test_foreign_class_cannot_pass(self):
        with self.assertRaises(ValueError):
            self.evaluate(transcript().replace(CLASS, "ForeignTests"))

    def test_skipped_and_failed_methods_cannot_pass(self):
        for status in ("skipped", "failed"):
            self.assertFalse(self.evaluate(transcript(status=status))["passed"])

    def test_missing_start_terminal_or_suite_cannot_pass(self):
        log = transcript()
        for line in log.splitlines(keepends=True):
            self.assertFalse(self.evaluate(log.replace(line, ""))["passed"])

    def test_duplicate_execution_cannot_pass(self):
        self.assertFalse(self.evaluate(transcript() * 2)["passed"])

    def test_nonzero_native_or_capture_status_cannot_pass(self):
        for test, capture in ((1, 0), (0, 1), (124, 0)):
            self.assertFalse(self.evaluate(transcript(), test, capture)["passed"])

    def test_unknown_or_duplicate_source_declaration_is_refused(self):
        for source in ("func testOther() {}", SOURCE + f"func {METHOD}() {{}}"):
            with self.assertRaises(ValueError):
                isolation.selected_receipt(source, transcript(), CLASS, METHOD, 0, 0)

    def fixture(self, directory):
        evidence = Path(directory)
        for classname, _ in isolation.COHORTS:
            shutil.copyfile(
                ROOT
                / "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests"
                / (classname + ".swift"),
                evidence / (classname + ".swift"),
            )
        return evidence

    def test_closed_real_source_inventory_and_reverse_execution_order(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = self.fixture(directory)
            expected = [(name, method) for name, method, _ in isolation.inventory(evidence)]
            self.assertEqual(len(expected), 21)
            observed = []

            def child(arguments, log):
                self.assertEqual(arguments[:2], ["swift", "test"])
                self.assertEqual(arguments[-2], "--filter")
                selected = arguments[-1].removeprefix("(^|[.])").removesuffix("$")
                name, method = selected.split("[/.]")
                observed.append((name, method))
                log.write_text(transcript(method).replace(CLASS, name), encoding="utf-8")
                return 0, 0

            with patch.object(isolation, "run_child", side_effect=child):
                for phase in ("forward", "reverse"):
                    self.assertEqual(
                        isolation.run(evidence, Path("package"), Path("scratch"), phase), 0
                    )
            self.assertEqual(observed, expected + list(reversed(expected)))
            for phase in ("forward", "reverse"):
                receipts = list((evidence / ("isolated-" + phase)).glob("*.json"))
                self.assertEqual(len(receipts), 22)
                summary = json.loads(
                    (evidence / ("isolated-" + phase) / "summary.json").read_text()
                )
                self.assertTrue(summary["passed"])
                self.assertEqual(summary["received_count"], 21)

    def test_first_refusal_cannot_skip_later_methods_or_publish_a_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = self.fixture(directory)
            calls = []

            def child(arguments, log):
                calls.append(arguments)
                log.write_text("No matching test cases were run", encoding="utf-8")
                return 0, 0

            with patch.object(isolation, "run_child", side_effect=child):
                self.assertEqual(
                    isolation.run(evidence, Path("package"), Path("scratch"), "forward"), 1
                )
            self.assertEqual(len(calls), 21)
            summary = json.loads((evidence / "isolated-forward/summary.json").read_text())
            self.assertFalse(summary["passed"])

    @POSIX_GROUPS
    def test_each_child_has_its_own_bounded_process_group_and_is_reaped(self):
        process = Mock(pid=321)
        process.wait.side_effect = [
            isolation.subprocess.TimeoutExpired("swift", 120),
            isolation.subprocess.TimeoutExpired("swift", 5),
            0,
        ]
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(isolation.subprocess, "Popen", return_value=process) as spawn:
                with (
                    patch.object(isolation.os, "killpg") as kill,
                    patch.object(isolation, "retire_group", return_value=True),
                ):
                    self.assertEqual(
                        isolation.run_child(["swift", "test"], Path(directory) / "log"), (124, 0)
                    )
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        self.assertEqual(
            kill.call_args_list,
            [call(321, isolation.signal.SIGTERM), call(321, isolation.signal.SIGKILL)],
        )
        self.assertEqual(
            process.wait.call_args_list, [call(timeout=120), call(timeout=5), call(timeout=5)]
        )

    @POSIX_GROUPS
    def test_exit_between_timeout_and_signal_is_reaped_and_remains_a_refusal(self):
        process = Mock(pid=321)
        process.wait.side_effect = [isolation.subprocess.TimeoutExpired("swift", 120), 0]
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(isolation.subprocess, "Popen", return_value=process):
                with (
                    patch.object(isolation.os, "killpg", side_effect=ProcessLookupError),
                    patch.object(isolation, "retire_group", return_value=True),
                ):
                    self.assertEqual(
                        isolation.run_child(["swift", "test"], Path(directory) / "log"), (124, 0)
                    )
        self.assertEqual(process.wait.call_count, 2)

    def test_unavailable_native_tool_cannot_publish_success(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(isolation.subprocess, "Popen", side_effect=FileNotFoundError):
                self.assertEqual(
                    isolation.run_child(["missing"], Path(directory) / "log"), (127, 0)
                )

    @POSIX_GROUPS
    def test_real_zero_exit_parent_with_live_descendant_is_refused_and_retired(self):
        controller = textwrap.dedent("""
            import ctypes, json, os, subprocess, sys, tempfile, threading, time
            from pathlib import Path
            sys.path.insert(0, sys.argv[1])
            import input_source_xctest_isolation as owner
            if sys.platform.startswith("linux"):
                assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
            with tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "log"
                child_pid = []
                def reap_exact_descendant():
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        try:
                            pid = int(log.read_text().strip())
                            child_pid[:] = [pid]
                            if sys.platform.startswith("linux"):
                                if os.waitpid(pid, os.WNOHANG)[0] == pid:
                                    return
                            else:
                                try:
                                    os.kill(pid, 0)
                                except ProcessLookupError:
                                    return
                        except (FileNotFoundError, ValueError, ChildProcessError):
                            pass
                        time.sleep(0.01)
                code = "import subprocess,sys; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(120)']); print(child.pid,flush=True)"
                reaper = threading.Thread(target=reap_exact_descendant)
                reaper.start()
                try:
                    owner.run_child([sys.executable, "-c", code], log)
                    raise AssertionError("zero-exit parent with live child was accepted")
                except owner.NativeChildRetirementError as error:
                    assert error.native_exit == 0
                    assert error.retired is True
                finally:
                    reaper.join(5)
                    assert not reaper.is_alive()
                assert child_pid
                print("real parent exit0 refused; exact descendant retired")
        """)
        result = isolation.subprocess.run(
            [sys.executable, "-c", controller, str(ROOT / "tools/diagnostics")],
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("real parent exit0 refused", result.stdout)

    def test_uncertain_retirement_aborts_both_phases_before_another_child(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = self.fixture(directory)

            def child(arguments, log):
                log.write_text("", encoding="utf-8")
                raise isolation.NativeChildRetirementError(0, False)

            with patch.object(isolation, "run_child", side_effect=child) as spawn:
                self.assertEqual(
                    isolation.run(evidence, Path("package"), Path("scratch"), "forward"), 75
                )
                self.assertEqual(
                    isolation.run(evidence, Path("package"), Path("scratch"), "reverse"), 75
                )
                self.assertEqual(spawn.call_count, 1)
            self.assertTrue((evidence / "isolation-retirement-refused.json").is_file())
            summary = json.loads((evidence / "isolated-forward/summary.json").read_text())
            self.assertFalse(summary["passed"])
            self.assertEqual(summary["received_count"], 1)

    def test_census_drift_and_missing_localization_cases_are_refused(self):
        for mutation in ("extra", "missing-localization"):
            with tempfile.TemporaryDirectory() as directory:
                evidence = self.fixture(directory)
                name = (
                    "NativeInputSourceSelectionTests"
                    if mutation == "extra"
                    else "EmbeddedFatalReportTests"
                )
                source = evidence / (name + ".swift")
                contents = source.read_text()
                contents = (
                    contents + "\nfunc testUnexpected() {}\n"
                    if mutation == "extra"
                    else contents.replace(isolation.LOCALIZATION_METHODS[0], "testForeign")
                )
                source.write_text(contents)
                with self.assertRaises(ValueError):
                    isolation.inventory(evidence)


if __name__ == "__main__":
    unittest.main()
