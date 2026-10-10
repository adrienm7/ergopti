#!/usr/bin/env python3
# tools/test/owned_suspended_image_portable_test.py
"""Compile the real image boundary; explicit native doubles give no Darwin credit."""

from pathlib import Path
import os
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPOSITORY = Path(__file__).resolve().parents[2]
NATIVE = REPOSITORY / "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility"
FIXTURE = REPOSITORY / "tools/test/fixtures/owned_suspended_image_portable.c"
EXPECTED = (
    "PASS 20 actual-C receiving-boundary controls; native SDK functions are explicit test doubles\n"
)
MUTANTS = {
    "mapped_image_proof_omitted": (
        "if ((error = ergopti_suspended_image_validate(executable, &expected, "
        "remaining, &mapped)) != 0) { return error; }",
        "mapped = expected;",
    ),
    "mapped_receipt_not_checked": (
        "if (mapped.pid != expected.pid || mapped.uid != expected.uid\n"
        "\t\t|| mapped.start_seconds != expected.start_seconds || "
        "mapped.start_microseconds != expected.start_microseconds\n"
        "\t\t|| mapped.device != device || mapped.inode != inode) { return ESTALE; }",
        "",
    ),
    "original_deadline_not_checked_after_return": (
        "if ((error = image_remaining(&started, remaining_ms, &remaining)) "
        "!= 0) { return error; }\n\t*identity = mapped;",
        "*identity = mapped;",
    ),
}


def no_core():
    """A deliberately aborting mutant must not leave a core in the checkout."""
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run_owned(arguments, cwd):
    """Retain the unreaped process-group authority through a bounded invocation."""
    interrupted = False

    def request_retirement(_number, _frame):
        nonlocal interrupted
        interrupted = True

    old_handlers = {
        number: signal.signal(number, request_retirement)
        for number in (signal.SIGINT, signal.SIGTERM)
    }
    process = None
    try:
        process = subprocess.Popen(
            arguments,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            preexec_fn=no_core,
        )
        deadline = time.monotonic() + 30
        while not interrupted and time.monotonic() < deadline:
            try:
                stdout, stderr = process.communicate(timeout=0.1)
                if interrupted:
                    raise KeyboardInterrupt
                return subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
            except subprocess.TimeoutExpired:
                continue
        # Our non-raising signal handler prevents Popen's KeyboardInterrupt
        # path from reaping the leader before this owned group is signaled.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)
        if interrupted:
            raise KeyboardInterrupt
        raise TimeoutError("The owned compiler/probe exceeded its finite deadline.")
    finally:
        if process is not None:
            process.stdout.close()
            process.stderr.close()
        for number, handler in old_handlers.items():
            signal.signal(number, handler)


class OwnedSuspendedImagePortable(unittest.TestCase):
    def setUp(self):
        if sys.platform not in ("linux", "darwin"):
            raise RuntimeError("The portable image boundary requires actual POSIX files.")
        compiler = shutil.which("cc")
        if compiler is None:
            raise RuntimeError("A genuine C compiler is required; the gate is not skipped.")
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-suspended-image-portable-")
        self.addCleanup(self.owner.cleanup)
        self.root = Path(self.owner.name)
        self.compiler = [
            compiler,
            "-std=c11",
            "-D_POSIX_C_SOURCE=200809L",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wshadow",
            "-Wconversion",
            "-Wsign-conversion",
            "-pedantic",
            "-O2",
        ]
        if sys.platform == "linux":
            self.compiler += ["-Dst_mtimespec=st_mtim", "-Dst_ctimespec=st_ctim"]
        self.compiler += ["-I", str(NATIVE / "include"), str(FIXTURE)]
        self.source = NATIVE / "OwnedSuspendedImageCompatibility.c"
        self.assertTrue(self.source.is_file(), "The real production boundary must exist.")

    def compile(self, source, name):
        output = self.root / name
        result = run_owned(self.compiler + [str(source), "-o", str(output)], self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        return output

    def test_literal_twenty_controls_receive_the_actual_compiled_boundary(self):
        output = self.compile(self.source, "actual-boundary")
        result = run_owned([str(output), str(self.root)], self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, EXPECTED)
        self.assertEqual(result.stderr, "")

    def test_interrupted_owner_reaps_the_exact_child_before_returning(self):
        receipt = self.root / "interrupted-child.pid"
        child = (
            "import os, pathlib, signal, sys, time; "
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
            "os.kill(os.getppid(), signal.SIGINT); time.sleep(60)"
        )
        with self.assertRaises(KeyboardInterrupt):
            run_owned([sys.executable, "-c", child, str(receipt)], self.root)
        identity = int(receipt.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(identity, 0)

    def test_compiled_mutants_fail_the_unchanged_literal_receiving_vectors(self):
        complete = self.source.read_text()
        active_boundary = (
            "\n// Exact active original owner and borrowed alias; no new PID authority.\n"
            "int ergopti_owned_active_image_validate("
        )
        self.assertEqual(complete.count(active_boundary), 1)
        original, active_suffix = complete.split(active_boundary)
        active_suffix = active_boundary + active_suffix
        for name, (needle, replacement) in MUTANTS.items():
            with self.subTest(mutation=name):
                self.assertEqual(original.count(needle), 1)
                source = self.root / (name + ".c")
                source.write_text(original.replace(needle, replacement) + active_suffix)
                output = self.compile(source, name)
                result = run_owned([str(output), str(self.root)], self.root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Assertion", result.stderr)
                self.assertNotEqual(result.stdout, EXPECTED)


if __name__ == "__main__":
    unittest.main()
