# tools/test/managed_ollama_signal_pid_publication_test.py

"""Receive the original signal control during empty and partial PID writes."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
OWNER = ROOT / "tools/test/managed_ollama_go_evidence_test.py"
ORIGINAL = "NativeGoSignalOwnershipTests.testFailedRetirementObservationPreservesDebtWithoutProof"

# Only the real write schedule changes. Process creation, the parent's original
# exists-then-SIGTERM sequence and every original retirement assertion remain.
PID_SCHEDULE = r"""
import json
import os
from pathlib import Path
import sys
import time

if "--signal-caller" in sys.argv:
    original_open = Path.open
    destination = Path(os.environ["CONTROL_PID"])

    class ScheduledWriter:
        def __init__(self, stream, path):
            self.stream = stream
            self.path = path
            self.fact = {"source_name": path.name}

        def __enter__(self):
            self.stream.__enter__()
            return self

        def __exit__(self, *args):
            result = self.stream.__exit__(*args)
            self.fact["stream_closed"] = self.stream.closed
            self.fact["destination_absent_at_close"] = not destination.exists()
            with original_open(Path(os.environ["PID_PUBLICATION_FACT"]), "x") as fact:
                json.dump(self.fact, fact)
            return result

        def write(self, data):
            self.fact["actual_pid"] = data
            if os.environ["PID_PUBLICATION_SCHEDULE"] == "partial":
                self.stream.write(data[:1])
                self.stream.flush()
            self.fact["bytes_before_pause"] = self.path.stat().st_size
            self.fact["destination_absent_before_pause"] = not destination.exists()
            # An empty or partial physical file exists during this interval.
            # The unmodified parent can observe it and send an actual signal.
            time.sleep(0.2)
            self.fact["destination_absent_after_pause"] = not destination.exists()
            if os.environ["PID_PUBLICATION_SCHEDULE"] == "partial":
                self.stream.seek(0)
                self.stream.truncate()
            return self.stream.write(data)

    def open_path(path, *args, **kwargs):
        stream = original_open(path, *args, **kwargs)
        mode = args[0] if args else kwargs.get("mode", "r")
        if path in (destination, destination.with_name(destination.name + ".pending")) and mode in ("w", "x"):
            return ScheduledWriter(stream, path)
        return stream

    Path.open = open_path
"""


class PidPublicationReceivingTests(unittest.TestCase):
    def receive_original_control(self, mode):
        with tempfile.TemporaryDirectory(prefix="signal-pid-publication-") as temporary:
            root = Path(temporary)
            hooks = root / "hooks"
            hooks.mkdir()
            (hooks / "sitecustomize.py").write_text(PID_SCHEDULE, encoding="utf-8")
            fact_path = root / "pid-publication.json"
            result = subprocess.run(
                [sys.executable, "-B", str(OWNER), ORIGINAL, "-v"],
                cwd=ROOT,
                env={
                    **os.environ,
                    "PYTHONPATH": str(hooks),
                    "PYTHONDONTWRITEBYTECODE": "1",
                    "PID_PUBLICATION_SCHEDULE": mode,
                    "PID_PUBLICATION_FACT": str(fact_path),
                },
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                encoding="utf-8",
                timeout=15,
            )
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn("Ran 1 test", result.stderr)
            self.assertRegex(result.stderr, r"\nOK\s*$")
            fact = json.loads(fact_path.read_text(encoding="utf-8"))
            self.assertEqual("pid.pending", fact["source_name"])
            self.assertEqual(0 if mode == "empty" else 1, fact["bytes_before_pause"])
            self.assertTrue(fact["actual_pid"].isdecimal())
            self.assertGreater(int(fact["actual_pid"]), 0)
            self.assertTrue(fact["destination_absent_before_pause"])
            self.assertTrue(fact["destination_absent_after_pause"])
            self.assertTrue(fact["stream_closed"])
            self.assertTrue(fact["destination_absent_at_close"])

    def test_empty_pending_pid_never_invites_early_cancellation(self):
        self.receive_original_control("empty")

    def test_partial_pending_pid_never_invites_early_cancellation(self):
        self.receive_original_control("partial")


if __name__ == "__main__":
    unittest.main()
