# tools/build/remap_runtime_phase_deadline_test.py
"""Pin the hard calibration deadline of the native phase owner the runtime build uses.

A hosted run once waited two hours on three xcodebuild children because the
phase owner only compared the clock after the child exited. These tests run
real children: a phase still running at its deadline is killed with its whole
process tree, refused with a named code and receipt, and progress is streamed.
"""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    "remap_runtime_build_deadline_subject", Path(__file__).with_name("remap_runtime_build.py")
)
BUILD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILD
SPEC.loader.exec_module(BUILD)
BASE = BUILD.BASE

# The child would sleep this long; the original unbounded wait outlives the
# assertion bound below, so it fails instead of passing late.
CHILD_SLEEP_SECONDS = 60
DEADLINE_SECONDS = 1.5
KILL_BOUND_SECONDS = 20
PROGRESS_SECONDS = 0.2

CHILD = textwrap.dedent(
    """
    import subprocess, sys, time
    grandchild = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(%d)"], start_new_session=True
    )
    with open(sys.argv[1], "w") as handle:
        handle.write(str(grandchild.pid))
    print("CompileC modeled/main.o main.cpp", flush=True)
    print("    indented command detail", flush=True)
    time.sleep(%d)
    """
    % (CHILD_SLEEP_SECONDS, CHILD_SLEEP_SECONDS)
)


def alive(pid):
    """Report whether a pid names a live, non-zombie process on macOS or Linux."""
    result = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
    )
    state = result.stdout.decode().strip()
    return bool(state) and not state.startswith("Z")


class PhaseDeadlineControls(unittest.TestCase):
    def setUp(self):
        self.owner = Path(tempfile.mkdtemp(prefix="phase-deadline-")).resolve()
        self.addCleanup(shutil.rmtree, self.owner, True)
        self.marker = self.owner / "grandchild.pid"
        self.script = self.owner / "child.py"
        self.script.write_text(CHILD)
        self.addCleanup(self.reap_grandchild)
        progress = mock.patch.object(BASE, "PHASE_PROGRESS_SECONDS", PROGRESS_SECONDS)
        progress.start()
        self.addCleanup(progress.stop)

    def reap_grandchild(self):
        if self.marker.exists():
            pid = int(self.marker.read_text())
            if alive(pid):
                os.kill(pid, 9)

    def command(self):
        return [sys.executable, str(self.script), str(self.marker)]

    def wait_for_marker(self):
        bound = time.monotonic() + KILL_BOUND_SECONDS
        while not self.marker.exists() or not self.marker.read_text():
            self.assertLess(time.monotonic(), bound, "the modeled child never started")
            time.sleep(0.05)
        return int(self.marker.read_text())

    def assert_killed(self, name, caught, elapsed, log):
        self.assertEqual(caught.exception.code, "phase_deadline")
        self.assertIn("killed: " + name, str(caught.exception))
        self.assertLess(elapsed, KILL_BOUND_SECONDS)
        receipt = json.loads((self.owner / (name + ".receipt.json")).read_text())
        self.assertEqual(receipt["status"], "refused")
        self.assertEqual(receipt["refusal"], "phase_deadline_killed")
        self.assertLess(receipt["exit_status"], 0)
        grandchild = int(self.marker.read_text())
        bound = time.monotonic() + 5
        while alive(grandchild) and time.monotonic() < bound:
            time.sleep(0.05)
        self.assertFalse(alive(grandchild), "a descendant in its own session survived")
        self.assertIn("[native-phase] " + name + ": started", log)
        self.assertIn("last: CompileC modeled/main.o main.cpp", log)
        self.assertIn("calibration deadline reached", log)
        self.assertIn("[native-phase] " + name + ": refused in", log)

    def test_foreground_phase_is_killed_at_its_deadline(self):
        log = io.StringIO()
        started = time.monotonic()
        with contextlib.redirect_stderr(log):
            with self.assertRaises(BASE.NativeBuildError) as caught:
                BASE.run_phase(
                    "core_build",
                    self.command(),
                    self.owner,
                    self.owner,
                    started + DEADLINE_SECONDS,
                )
        self.assert_killed("core_build", caught, time.monotonic() - started, log.getvalue())

    def test_retained_phase_is_killed_at_its_deadline(self):
        log, owners = io.StringIO(), []
        started = time.monotonic()
        with contextlib.redirect_stderr(log):
            operation = BASE.begin_phase(
                "console_build",
                self.command(),
                self.owner,
                self.owner,
                started + DEADLINE_SECONDS,
                owners.append,
            )
            self.assertEqual(owners, [operation])
            self.wait_for_marker()
            with self.assertRaises(BASE.NativeBuildError) as caught:
                BASE.finish_phase(operation)
        self.assertTrue(operation.waited)
        self.assertTrue(operation.finished)
        self.assert_killed("console_build", caught, time.monotonic() - started, log.getvalue())

    def test_phase_within_its_deadline_passes_without_refusal(self):
        log = io.StringIO()
        with contextlib.redirect_stderr(log):
            record = BASE.run_phase(
                "cli_build",
                [sys.executable, "-c", "print('done')"],
                self.owner,
                self.owner,
                time.monotonic() + KILL_BOUND_SECONDS,
            )
        self.assertEqual(record["status"], "passed")
        self.assertNotIn("refusal", record)
        self.assertIn("[native-phase] cli_build: passed in", log.getvalue())

    def test_build_command_bounds_compiler_jobs(self):
        command = BUILD.build_command("/usr/bin/xcodebuild", self.owner)
        self.assertEqual(command[command.index("-jobs") + 1], "2")


if __name__ == "__main__":
    unittest.main()
