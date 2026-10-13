# tools/diagnostics/core_sdk_entrypoint_test.py
"""Receive the genuine SDK main guard without starting its native worker.

The original guard below was frozen before the correction. Each subprocess
executes that guard or the actual current source guard, with only main injected.
These controls establish exit propagation and safe failure classification;
they grant no SDK, installation, input or release authority.
"""

import ast
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BEFORE_GUARD = """if __name__ == "__main__":
    try:
        sys.exit(main())
    except BaseException as error:
        print("Core SDK receiving refused: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
"""
BEFORE_SHA256 = "5773ca19ff11a1e9b779aa763b0cec86a0b4f43ff7bcd587fa457258166f571b"
CURRENT = Path(__file__).resolve().parents[1] / "build/core_sdk/run_core_sdk.py"


def current_guard():
    """Extract the one genuine __main__ boundary, without importing SDK owners."""
    body = CURRENT.read_text(encoding="utf-8")
    guards = [
        item
        for item in ast.parse(body).body
        if isinstance(item, ast.If)
        and isinstance(item.test, ast.Compare)
        and isinstance(item.test.left, ast.Name)
        and item.test.left.id == "__name__"
        and len(item.test.ops) == 1
        and isinstance(item.test.ops[0], ast.Eq)
        and len(item.test.comparators) == 1
        and isinstance(item.test.comparators[0], ast.Constant)
        and item.test.comparators[0].value == "__main__"
    ]
    if len(guards) != 1:
        raise ValueError("One actual SDK main guard is required")
    return ast.get_source_segment(body, guards[0]) + "\n"


def invoke(guard, action):
    """Execute the captured source boundary in a finite independent interpreter."""
    with tempfile.TemporaryDirectory(prefix="core-sdk-main-guard-") as directory:
        actor = Path(directory) / "guard.py"
        actor.write_text("import sys\ndef main():\n    " + action + "\n" + guard, encoding="utf-8")
        return subprocess.run(
            [sys.executable, "-B", str(actor)], capture_output=True, timeout=10, check=False
        )


class MainGuardControls(unittest.TestCase):
    def setUp(self):
        self.assertEqual(hashlib.sha256(BEFORE_GUARD.encode()).hexdigest(), BEFORE_SHA256)
        self.current = current_guard()

    def test_success_zero_is_not_caught_as_a_failure(self):
        before = invoke(BEFORE_GUARD, "return 0")
        self.assertEqual(before.returncode, 1)
        self.assertEqual(before.stdout, b"")
        self.assertEqual(before.stderr, b"Core SDK receiving refused: SystemExit\n")
        current = invoke(self.current, "return 0")
        self.assertEqual(current.returncode, 0)
        self.assertEqual(current.stdout, b"")
        self.assertEqual(current.stderr, b"")

    def test_nonzero_main_result_remains_exact(self):
        before = invoke(BEFORE_GUARD, "return 7")
        self.assertEqual(before.returncode, 1)
        self.assertEqual(before.stderr, b"Core SDK receiving refused: SystemExit\n")
        current = invoke(self.current, "return 7")
        self.assertEqual(current.returncode, 7)
        self.assertEqual(current.stdout, b"")
        self.assertEqual(current.stderr, b"")

    def test_runtime_failure_keeps_safe_classification(self):
        for guard in (BEFORE_GUARD, self.current):
            actual = invoke(guard, "raise RuntimeError('seeded-private-failure-value')")
            self.assertEqual(actual.returncode, 1)
            self.assertEqual(actual.stdout, b"")
            self.assertEqual(actual.stderr, b"Core SDK receiving refused: RuntimeError\n")
            self.assertNotIn(b"seeded-private-failure-value", actual.stderr)

    def test_keyboard_interrupt_keeps_broad_failure_boundary(self):
        for guard in (BEFORE_GUARD, self.current):
            actual = invoke(guard, "raise KeyboardInterrupt()")
            self.assertEqual(actual.returncode, 1)
            self.assertEqual(actual.stdout, b"")
            self.assertEqual(actual.stderr, b"Core SDK receiving refused: KeyboardInterrupt\n")

    def test_main_system_exit_remains_a_classified_failure(self):
        for guard in (BEFORE_GUARD, self.current):
            actual = invoke(guard, "raise SystemExit(42)")
            self.assertEqual(actual.returncode, 1)
            self.assertEqual(actual.stdout, b"")
            self.assertEqual(actual.stderr, b"Core SDK receiving refused: SystemExit\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
