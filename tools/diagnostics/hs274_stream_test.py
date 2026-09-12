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
from types import SimpleNamespace

from hs274_stream import decimal, read_stream, validate_stream, fixture_drain, validate_interruption
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


def remap_module():
    spec = importlib.util.spec_from_file_location("hs274_remap", Path(__file__).with_name("hs274-remap.py"))
    remap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(remap)
    return remap


class StreamTests(unittest.TestCase):
    def test_ignored_fixture_preserves_escape_and_space_without_ledger_rules_running(self):
        remap = remap_module()
        device = {"vendor_id": 1, "product_id": 2}
        profiles = [remap.fixture_profile(device, Path("ledger"), ignored)["profiles"][0]
                    for ignored in (False, True)]
        self.assertEqual(profiles[0]["complex_modifications"], profiles[1]["complex_modifications"])
        self.assertEqual(profiles[1]["devices"], [{"identifiers": dict(device, is_keyboard=True), "ignore": True}])
        self.assertIs(profiles[0]["devices"][0]["ignore"], False)
        for ignored in (False, True):
            escape = 53 if ignored else 49
            native = {"ignored_mode": ignored, "escape_as_space": not ignored,
                      "escape_passthrough": ignored, "space_pair_observed": True,
                      "events": [{"type": kind, "keycode": code} for kind, code in
                                 [(10, escape), (11, escape), (10, 49), (11, 49)]]}
            remap.validate_native_output(native, ignored)
            with self.assertRaises(ValueError):
                remap.validate_native_output(native, not ignored)
            for index in range(4):
                broken = copy.deepcopy(native)
                broken["events"][index]["keycode"] = 0
                with self.subTest(ignored=ignored, index=index), self.assertRaises(ValueError):
                    remap.validate_native_output(broken, ignored)
            for field in ("ignored_mode", "escape_as_space", "escape_passthrough", "space_pair_observed"):
                broken = dict(native)
                broken[field] = not broken[field]
                with self.subTest(ignored=ignored, field=field), self.assertRaises(ValueError):
                    remap.validate_native_output(broken, ignored)

    def test_interruption_requires_exact_terminal_loss_for_the_idle_lease(self):
        _, frames = fixture()
        opened = dict(frames[0], lease="3")
        terminal = dict(opened, kind="lost", reason="interrupted")
        output = encode([opened, terminal])
        self.assertEqual(validate_interruption(output, opened)["terminal"], terminal)
        for field, value in (("version", True), ("lease", "2"), ("reason", "overflow"),
                             ("incarnation", "other"), ("kind", "batch")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_interruption(encode([opened, dict(terminal, **{field: value})]), opened)
        for malformed in (encode([opened]), output[:-1], output + "\n", encode([opened, terminal, terminal]),
                          output.replace('"reason": "interrupted"', '"reason": "other", "reason": "interrupted"')):
            with self.subTest(output=malformed), self.assertRaises(ValueError):
                validate_interruption(malformed, opened)

    def test_fixture_drain_requires_trailing_auxiliaries_and_exact_shape(self):
        capture, frames = fixture()
        stream = read_stream(encode(frames))
        complete = fixture_drain(capture["records"][0]["device"])
        for count in range(len(stream["records"])):
            self.assertFalse(complete(dict(stream, records=stream["records"][:count])))
        self.assertTrue(complete(stream))
        for field in ("device", "value", "usage"):
            malformed = copy.deepcopy(stream)
            malformed["records"][-1][field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                complete(malformed)
        with self.assertRaises(ValueError):
            complete(dict(stream, records=stream["records"] + [stream["records"][-1]]))

    def test_fixture_release_follows_client_exit_and_rejects_premature_exit(self):
        remap = remap_module()
        capture, frames = fixture()
        for producer_exit, client_exit in ((None, 143), (0, 143), (None, -9)):
            with self.subTest(producer_exit=producer_exit, client_exit=client_exit), tempfile.TemporaryDirectory(prefix="hs274-drain-") as directory:
                root = Path(directory)
                stream_path, drained_path = root / "stream", root / "drained"
                stream_path.write_text(encode(frames), encoding="utf-8")
                client = SimpleNamespace(poll=lambda: None, returncode=None)
                producer = SimpleNamespace(poll=lambda: producer_exit)
                closed = []

                def close():
                    self.assertFalse(drained_path.exists())
                    client.returncode = client_exit
                    closed.append(True)

                def before_release():
                    self.assertEqual(closed, [True])
                    self.assertFalse(drained_path.exists())
                    return "successor"

                arguments = (stream_path, client, producer, SimpleNamespace(close=close),
                             drained_path, capture["records"][0]["device"], before_release)
                if producer_exit is None and client_exit == 143:
                    self.assertEqual(remap.finish_fixture_stream(*arguments), "successor")
                    self.assertEqual(drained_path.read_text(encoding="utf-8"), "drained\n")
                    self.assertEqual(closed, [True])
                else:
                    with self.assertRaises(RuntimeError):
                        remap.finish_fixture_stream(*arguments)
                    self.assertFalse(drained_path.exists())
                    self.assertEqual(closed, [] if producer_exit is not None else [True])

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
        remap = remap_module()
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
