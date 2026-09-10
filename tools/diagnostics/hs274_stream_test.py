# tools/diagnostics/hs274_stream_test.py
"""Keep missing stream evidence and malformed frames from passing the native gate."""

import copy
import json
import importlib.util
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest

from hs274_stream import decimal, read_stream, validate_stream
from hs274_disconnect import disconnected_capture


def fixture():
    capture = json.loads((Path(__file__).with_name("fixtures") / "hs274-native-capture.json").read_text(encoding="utf-8"))
    opened = {"version": 1, "kind": "opened", "coverage": "fixture_only",
              "incarnation": "868caf13-2110-4244-8fc2-12d490504a09", "lease": "1"}
    records = copy.deepcopy(capture["records"])
    for row in records:
        for field in ("sequence", "device", "timestamp", "value"):
            row[field] = str(row[field])
    frames = [opened] + [dict(opened, kind="batch", records=records[i:i + 4]) for i in range(0, len(records), 4)]
    return capture, frames


def encode(frames):
    return "".join(json.dumps(frame) + "\n" for frame in frames)


class StreamTests(unittest.TestCase):
    def test_disconnected_pipe_requires_explicit_failure_and_reaps_child(self):
        child = "\n".join([
            "import os, sys",
            "try: os.write(1, b'opened\\n')",
            "except OSError:",
            " print('Physical capture failed: Capture output disconnected', file=sys.stderr)",
            " sys.exit(1)",
            "sys.exit(0)",
        ])
        with tempfile.TemporaryDirectory(prefix="hs274-disconnect-") as directory:
            report = {}
            disconnected_capture([sys.executable, "-c", child], Path(directory), report)
            self.assertTrue(report["processes"]["disconnected-stream"]["reaped"])
            self.assertEqual(report["processes"]["disconnected-stream"]["exit"], 1)

    def test_disconnected_pipe_rejects_success_unrelated_error_and_timeout(self):
        for child, error in (("pass", RuntimeError),
                             ("raise RuntimeError('unrelated')", RuntimeError),
                             ("import time; time.sleep(30)", subprocess.TimeoutExpired)):
            with self.subTest(child=child), tempfile.TemporaryDirectory(prefix="hs274-disconnect-") as directory:
                report = {}
                with self.assertRaises(error):
                    disconnected_capture([sys.executable, "-c", child], Path(directory), report, timeout=0.5)
                self.assertTrue(report["processes"]["disconnected-stream"]["reaped"])
                if error is subprocess.TimeoutExpired:
                    self.assertTrue(report["processes"]["disconnected-stream"]["forced_cleanup"])

    def test_real_process_scope_separates_diagnostics_from_protocol(self):
        spec = importlib.util.spec_from_file_location("hs274_remap", Path(__file__).with_name("hs274-remap.py"))
        remap = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(remap)
        _, frames = fixture()
        command = [sys.executable, "-c", "import sys; print(sys.argv[1]); print('diagnostic', file=sys.stderr)",
                   json.dumps(frames[0])]
        with tempfile.TemporaryDirectory(prefix="hs274-stream-scope-") as directory:
            output = Path(directory)
            for separate in (False, True):
                report = {}
                name = str(separate)
                with remap.owned_process(command, name, output, report, separate_stderr=separate) as process:
                    self.assertEqual(process.wait(timeout=5), 0)
                self.assertTrue(report["processes"][name]["reaped"])
                stdout = (output / ("hs274-remap-" + name + ".log")).read_text(encoding="utf-8")
                if separate:
                    self.assertEqual(read_stream(stdout)["opened"], frames[0])
                    self.assertEqual((output / ("hs274-remap-" + name + "-stderr.log")).read_text(encoding="utf-8").strip(), "diagnostic")
                else:
                    with self.assertRaises(ValueError):
                        read_stream(stdout)

    def test_preserves_all_twenty_independent_native_records(self):
        capture, frames = fixture()
        self.assertEqual(validate_stream(encode(frames), capture)["records"], capture["records"])

    def test_partial_observation_never_makes_final_truncation_pass(self):
        _, frames = fixture()
        output = encode(frames)
        self.assertIsNone(read_stream('{"version":', partial=True))
        self.assertEqual(read_stream(output[:-5], partial=True)["records"], read_stream(encode(frames[:-1]))["records"])
        for malformed in ("", output[:-1], encode(frames[1:]), output + "log\n", output + "\n"):
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                read_stream(malformed)

    def test_loss_identity_changes_duplicate_and_missing_records_fail(self):
        capture, frames = fixture()
        variants = [frames + [frames[-1]], frames[:-1]]
        for field, value in (("kind", "lost"), ("lease", "2"), ("version", True),
                             ("incarnation", "other"), ("coverage", "all_devices"), ("records", [])):
            candidate = copy.deepcopy(frames)
            candidate[1][field] = value
            variants.append(candidate)
        for candidate in variants:
            with self.subTest(candidate=candidate), self.assertRaises(ValueError):
                validate_stream(encode(candidate), capture)

    def test_changed_values_and_noncanonical_types_fail(self):
        capture, frames = fixture()
        for field, value in (("sequence", "2"), ("device", "2"), ("timestamp", "0"),
                             ("value", "9"), ("has_page", 1), ("page", True), ("usage", 44)):
            candidate = copy.deepcopy(frames)
            candidate[1]["records"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_stream(encode(candidate), capture)

    def test_duplicate_json_field_and_invalid_handshake_fail(self):
        _, frames = fixture()
        with self.assertRaises(ValueError):
            read_stream(encode(frames).replace('"version": 1', '"version": 2, "version": 1', 1))
        for field, value in (("lease", "0"), ("incarnation", ""), ("version", True)):
            candidate = copy.deepcopy(frames)
            candidate[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                read_stream(encode(candidate))

    def test_decimal_extremes_are_exact(self):
        self.assertEqual(decimal("18446744073709551615"), (1 << 64) - 1)
        self.assertEqual(decimal("-9223372036854775808", -(1 << 63), (1 << 63) - 1), -(1 << 63))
        for value in (1, True, "01", "+1", "-0", " 1", "1 ", "١", "18446744073709551616"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                decimal(value)


if __name__ == "__main__":
    unittest.main()
