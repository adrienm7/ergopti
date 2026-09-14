# tools/diagnostics/hs274_stream_test.py
"""Keep missing stream evidence and malformed frames from passing the native gate."""

import copy
from datetime import datetime, timezone
import io
import json
import importlib.util
from pathlib import Path
import sys
import tempfile
import subprocess
import unittest
from types import SimpleNamespace

from hs274_stream import decimal, read_stream, validate_stream, fixture_drain, validate_interruption, validate_successor
from hs274_disconnect import disconnected_capture
from hs274_baseline import MARKER as BASELINE_MARKER, read_baseline, read_observation_baselines, require_held_baseline, validate_baseline_native, validate_baseline_capture, wait_baseline, require_stream_held_baseline
from hs274_capture import MARKER as CAPTURE_MARKER
from unittest.mock import patch


def baseline_fixture():
    probe = {"device": "41", "coverage": "fixture_only", "enumerated": True,
             "exhausted": False, "elements": []}
    for index, usage in enumerate((41, 44)):
        start = 100 + index * 4
        sample = {"status": 0, "returned_value": True, "started": str(start),
                  "finished": str(start + 1), "timestamp": "90", "value": "0", "value_cookie": index + 1}
        updated = dict(sample, started=str(start + 2), finished=str(start + 3), value=str(index))
        probe["elements"].append({"page": 7, "usage": usage, "cookie": index + 1,
                                  "cached": sample, "updated": updated})
    return probe


class BaselineTests(unittest.TestCase):
    def test_retained_native_held_consumer_preserves_release_and_single_credit(self):
        from hs274_hammerspoon import validate_consumer
        path = Path(__file__).parent / "fixtures" / "hs274-native-held-consumer.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        frames = [json.loads(line) for line in evidence["stream_output"].splitlines()]
        initial = read_stream(encode([frame for frame in frames if frame["kind"] != "batch"]))
        device = evidence["native"]["registry_entry_id"]
        boundary = require_stream_held_baseline(initial, device)
        probe = require_held_baseline(BASELINE_MARKER + json.dumps(evidence["probe"]["probe"]) + "\n",
                                      device, {41: 0, 44: 1}, source="kernel")
        released = validate_baseline_native(evidence["native"], probe)
        self.assertLess(boundary, released)
        capture_output = CAPTURE_MARKER + json.dumps(evidence["capture"]) + "\n"
        capture = validate_baseline_capture(capture_output, device, released)
        stream = validate_stream(evidence["stream_output"], capture)
        self.assertEqual(len(stream["records"]), 15)
        self.assertTrue(fixture_drain(device, held=True)(stream))
        utc_clock = SimpleNamespace(fromtimestamp=lambda epoch: datetime.fromtimestamp(epoch, timezone.utc))
        with patch("hs274_hammerspoon.datetime", utc_clock):
            validate_consumer(evidence["hammerspoon"], capture, held=True)
            with self.assertRaises(ValueError):
                validate_consumer(dict(evidence["hammerspoon"], counts={"49": 2}), capture, held=True)
        missing = copy.deepcopy(stream)
        missing["records"] = [row for row in missing["records"] if row["sequence"] != 8]
        with self.assertRaises(ValueError):
            fixture_drain(device, held=True)(missing)

    def test_stream_holds_exact_space_before_release_and_drains_all_native_rows(self):
        state = {"keyboard": True, "keys": {109: {"usage": 44, "down": True},
                                           106: {"usage": 41, "down": False}}}
        initial = {"records": [], "baseline": {"complete": True, "boundary": 100,
                                               "devices": {41: state}}}
        self.assertEqual(require_stream_held_baseline(initial, 41), 100)
        for change in ("incomplete", "records", "missing", "released", "extra"):
            broken = copy.deepcopy(initial)
            if change == "incomplete": broken["baseline"]["complete"] = False
            elif change == "records": broken["records"] = [{}]
            elif change == "missing": broken["baseline"]["devices"] = {}
            elif change == "released": broken["baseline"]["devices"][41]["keys"][109]["down"] = False
            else: broken["baseline"]["devices"][41]["keys"][106]["down"] = True
            with self.subTest(change=change), self.assertRaises(ValueError):
                require_stream_held_baseline(broken, 41)
        path = Path(__file__).parent / "fixtures" / "hs274-native-cookie-held.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        records = evidence["capture"]["records"]
        drain = fixture_drain(records[0]["device"], held=True)
        for count in range(len(records)):
            self.assertFalse(drain({"records": records[:count]}))
        self.assertTrue(drain({"records": records}))
        with self.assertRaises(ValueError):
            drain({"records": records + [dict(records[-1], sequence=len(records) + 1)]})
        with self.assertRaises(ValueError):
            drain({"records": records[:7] + records[8:]})
        remap = remap_module()
        with tempfile.TemporaryDirectory(prefix="hs274-held-drain-") as directory:
            drained = Path(directory) / "drained"
            client = SimpleNamespace(returncode=None)
            closed = []
            def wait_stream(path, owner, predicate, seconds, acknowledge):
                self.assertIs(owner, client)
                self.assertFalse(acknowledge)
                self.assertTrue(predicate({"records": records}))
                self.assertFalse(drained.exists())
            def close():
                self.assertFalse(drained.exists())
                client.returncode = 143
                closed.append(True)
            def successor():
                self.assertEqual(closed, [True])
                self.assertFalse(drained.exists())
                return "next lease"
            with patch.object(remap, "wait_stream", side_effect=wait_stream):
                self.assertEqual(remap.finish_fixture_stream(Path(directory) / "stream", client,
                    SimpleNamespace(poll=lambda: None), SimpleNamespace(close=close), drained,
                    records[0]["device"], successor, acknowledge=False, held=True), "next lease")
            self.assertEqual(drained.read_text(encoding="utf-8"), "drained\n")

    def test_retained_held_cookie_keeps_release_and_fresh_press(self):
        path = Path(__file__).parent / "fixtures" / "hs274-native-cookie-held.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        device = evidence["native"]["registry_entry_id"]
        probe = require_held_baseline(BASELINE_MARKER + json.dumps(evidence["probe"]) + "\n",
                                      device, {41: 0, 44: 1}, source="kernel")
        released = validate_baseline_native(evidence["native"], probe)
        capture = evidence["capture"]
        self.assertEqual(validate_baseline_capture(CAPTURE_MARKER + json.dumps(capture) + "\n",
                                                   device, released), capture)
        held = evidence["held_inventory_element"]
        self.assertEqual((held["usage"], held["sample"]["value"]), (44, "1"))
        keys = [row for row in capture["records"] if row["page"] == 7 and 4 <= row["usage"] <= 255]
        self.assertEqual([row["value"] for row in keys], [0, 1, 0])
        self.assertTrue(all(row["has_cookie"] is True and row["cookie"] == held["cookie"] for row in keys))
        missing = copy.deepcopy(capture)
        missing["records"] = [row for row in missing["records"] if row["sequence"] != keys[1]["sequence"]]
        missing["seen"] = len(missing["records"])
        for sequence, row in enumerate(missing["records"], 1):
            row["sequence"] = sequence
        with self.assertRaisesRegex(ValueError, "fresh physical press"):
            validate_baseline_capture(CAPTURE_MARKER + json.dumps(missing) + "\n", device, released)

    def test_retained_native_kernel_baseline_preserves_inherited_and_fresh_space(self):
        path = Path(__file__).parent / "fixtures" / "hs274-native-held-baseline.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        device = evidence["native"]["registry_entry_id"]
        output = BASELINE_MARKER + json.dumps(evidence["probe"]) + "\n"
        probe = require_held_baseline(output, device, {41: 0, 44: 1}, source="kernel")
        released = validate_baseline_native(evidence["native"], probe)
        capture = CAPTURE_MARKER + json.dumps(evidence["capture"]) + "\n"
        self.assertEqual(validate_baseline_capture(capture, device, released), evidence["capture"])
        # Native forced reads return cached pointers alongside failure statuses.
        # Replaying them as successful queries must not silently admit held state.
        self.assertFalse(read_baseline(output, device, source="forced")["acquired"])
        with self.assertRaisesRegex(ValueError, "did not establish"):
            require_held_baseline(output, device, {41: 0, 44: 1}, source="forced")
        missing_press = copy.deepcopy(evidence["capture"])
        missing_press["records"] = [row for row in missing_press["records"] if not (
            row["timestamp"] >= released and row["page"] == 7 and row["usage"] == 44 and row["value"] == 1)]
        missing_press["seen"] = len(missing_press["records"])
        for sequence, row in enumerate(missing_press["records"], 1):
            row["sequence"] = sequence
        with self.assertRaisesRegex(ValueError, "fresh physical press"):
            validate_baseline_capture(CAPTURE_MARKER + json.dumps(missing_press) + "\n", device, released)

    def test_monitor_restarts_retain_distinct_observations_without_selecting_held_state(self):
        first, second = baseline_fixture(), baseline_fixture()
        second["elements"][1]["updated"]["value"] = "0"
        lines = [BASELINE_MARKER + json.dumps(probe) + "\n" for probe in (first, second)]
        output = "unrelated diagnostic\n" + "".join(lines)
        observations = read_observation_baselines(output, 41)
        self.assertEqual([value["probe"] for value in observations], [first, second])
        self.assertEqual([value["held"][44] for value in observations], [1, 0])
        with self.assertRaisesRegex(ValueError, "one complete"):
            read_baseline(output, 41)
        with self.assertRaises(ValueError):
            require_held_baseline(output, 41, {41: 0, 44: 1})

    def test_observation_collection_validates_every_record_and_requires_complete_evidence(self):
        valid = BASELINE_MARKER + json.dumps(baseline_fixture()) + "\n"
        malformed = baseline_fixture()
        malformed["device"] = "42"
        wrong_device = BASELINE_MARKER + json.dumps(malformed) + "\n"
        for output in ("", "diagnostic\n", valid + valid.rstrip(), valid + wrong_device,
                       valid + BASELINE_MARKER + "{}\n"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                read_observation_baselines(output, 41)

    def test_kernel_source_requires_explicit_selection_and_retains_forced_refusal(self):
        probe = baseline_fixture()
        probe["elements"][1]["cached"]["value"] = "1"
        for element in probe["elements"]:
            updated = element["updated"]
            element["updated"] = {key: updated[key] for key in ("started", "finished")}
            element["updated"].update(status=-536870165, returned_value=True)
        output = BASELINE_MARKER + json.dumps(probe) + "\n"
        self.assertFalse(read_baseline(output, 41)["acquired"])
        result = require_held_baseline(output, 41, {41: 0, 44: 1}, source="kernel")
        self.assertEqual(result["source"], "kernel")
        self.assertEqual(result["held"], {41: 0, 44: 1})
        self.assertEqual(result["probe"], probe)
        for source in ("", "automatic", None):
            with self.subTest(source=source), self.assertRaises(ValueError):
                read_baseline(output, 41, source=source)

    def test_kernel_failure_does_not_borrow_successful_forced_values(self):
        probe = baseline_fixture()
        probe["elements"][1]["cached"] = {"status": -1, "returned_value": True,
                                           "started": "104", "finished": "105"}
        output = BASELINE_MARKER + json.dumps(probe) + "\n"
        self.assertTrue(read_baseline(output, 41)["acquired"])
        result = read_baseline(output, 41, source="kernel")
        self.assertFalse(result["acquired"])
        self.assertIsNone(result["held"])

    def test_native_release_must_follow_acquisition_and_preserve_the_fresh_pair(self):
        probe = read_baseline(BASELINE_MARKER + json.dumps(baseline_fixture()) + "\n", 41)
        native = {"baseline_mode": True, "baseline_down_observed": True, "space_pair_observed": True,
                  "metadata_restored": True, "metadata_work_completed": True, "transport_error": False,
                  "reports_queued": 4, "baseline_release_at": "200", "baseline_events": [{"type": 10, "keycode": 49}],
                  "events": [{"type": 10, "keycode": 49}, {"type": 11, "keycode": 49}]}
        self.assertEqual(validate_baseline_native(native, probe), 200)
        for change in ({"baseline_release_at": "100"}, {"baseline_events": []}, {"events": native["events"] * 2},
                       {"reports_queued": 3}, {"metadata_restored": False}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_baseline_native(dict(native, **change), probe)

    def test_raw_initial_held_input_is_retained_but_fresh_release_press_release_is_required(self):
        rows = [{"device": 41, "timestamp": stamp, "sequence": index + 1, "has_page": True,
                 "has_usage": True, "page": 7, "usage": 44, "value": value}
                for index, (stamp, value) in enumerate(((100, 1), (200, 0), (300, 1), (400, 0)))]
        capture = {"coverage": "fixture_only", "seen": 4, "overflow": 0, "contention": 0, "records": rows}
        output = CAPTURE_MARKER + json.dumps(capture) + "\n"
        self.assertEqual(validate_baseline_capture(output, 41, 200), capture)
        for index, change in ((0, {"value": 0}), (1, {"value": 1}), (2, {"value": 0}), (3, {"value": 1}),
                              (0, {"device": 42}), (0, {"sequence": 2})):
            mutated = copy.deepcopy(capture)
            mutated["records"][index].update(change)
            with self.subTest(index=index, change=change), self.assertRaises(ValueError):
                validate_baseline_capture(CAPTURE_MARKER + json.dumps(mutated) + "\n", 41, 200)

    def test_probe_wait_requires_a_complete_line_from_the_live_core(self):
        output = BASELINE_MARKER + json.dumps(baseline_fixture()) + "\n"
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "core.log"
            path.write_text(output.rstrip(), encoding="utf-8")
            clock = [0.0]
            def settle(seconds):
                clock[0] += seconds
                path.write_text(output, encoding="utf-8")
            with patch("hs274_baseline.time.monotonic", side_effect=lambda: clock[0]), patch("hs274_baseline.time.sleep", side_effect=settle):
                self.assertTrue(wait_baseline(path, SimpleNamespace(poll=lambda: None), 41, 1)["acquired"])
            with self.assertRaisesRegex(RuntimeError, "Core exited"):
                wait_baseline(path, SimpleNamespace(poll=lambda: 1), 41, 1)

    def test_forced_state_is_used_and_cached_read_is_retained(self):
        probe = baseline_fixture()
        result = require_held_baseline(BASELINE_MARKER + json.dumps(probe) + "\n", 41, {41: 0, 44: 1})
        self.assertEqual(result["held"], {41: 0, 44: 1})
        self.assertEqual(result["probe"]["elements"][1]["cached"]["value"], "0")

    def test_refused_or_missing_updated_value_never_becomes_an_empty_baseline(self):
        for status, returned in ((-1, False), (-1, True), (0, False)):
            with self.subTest(status=status, returned=returned):
                probe = baseline_fixture()
                probe["elements"][1]["updated"] = {"status": status, "returned_value": returned,
                                                    "started": "106", "finished": "107"}
                output = BASELINE_MARKER + json.dumps(probe) + "\n"
                result = read_baseline(output, 41)
                self.assertFalse(result["acquired"])
                self.assertIsNone(result["held"])
                with self.assertRaises(ValueError):
                    require_held_baseline(output, 41, {41: 0, 44: 0})

    def test_incomplete_inventory_cannot_publish_held_state(self):
        for field, value in (("enumerated", False), ("exhausted", True), ("elements", [])):
            probe = baseline_fixture()
            probe[field] = value
            self.assertFalse(read_baseline(BASELINE_MARKER + json.dumps(probe) + "\n", 41)["acquired"])

    def test_corrupt_identity_timing_and_value_are_rejected(self):
        mutations = (
            lambda p: p.update(device="42"),
            lambda p: p["elements"][1].update(usage=41),
            lambda p: p["elements"][1].update(cookie=1),
            lambda p: p["elements"][0]["updated"].update(value_cookie=2),
            lambda p: p["elements"][0]["updated"].update(started="99"),
            lambda p: p["elements"][0]["updated"].update(timestamp="999"),
            lambda p: p["elements"][0]["updated"].update(status=True),
            lambda p: p["elements"][0]["updated"].update(value="2"),
            lambda p: p["elements"][0]["updated"].update(status=-1),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                probe = baseline_fixture()
                mutate(probe)
                with self.assertRaises(ValueError):
                    read_baseline(BASELINE_MARKER + json.dumps(probe) + "\n", 41)

    def test_missing_duplicate_truncated_and_duplicate_field_receipts_are_rejected(self):
        output = BASELINE_MARKER + json.dumps(baseline_fixture()) + "\n"
        for bad in ("", output + output, output.rstrip(), output.replace('"device": "41"', '"device": "41", "device": "41"')):
            with self.assertRaises(ValueError):
                read_baseline(bad, 41)

    def test_successful_io_must_match_the_controlled_held_key(self):
        with self.assertRaises(ValueError):
            require_held_baseline(BASELINE_MARKER + json.dumps(baseline_fixture()) + "\n", 41, {41: 0, 44: 0})


def fixture():
    capture = json.loads((Path(__file__).with_name("fixtures") / "hs274-native-capture.json").read_text(encoding="utf-8"))
    # This historical receipt predates cookie capture; preserve that absence.
    for row in capture["records"]:
        row.update(has_cookie=False, cookie=0)
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
    def test_retained_native_paged_baseline_preserves_delivery_and_successor(self):
        from hs274_hammerspoon import validate_consumer
        path = Path(__file__).parent / "fixtures" / "hs274-native-paged-baseline.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        stream = validate_stream(evidence["stream_output"], evidence["capture"])
        baseline = stream["baseline"]
        self.assertTrue(baseline["complete"])
        self.assertEqual(baseline["received_rows"], 496)
        self.assertEqual(sorted(device["elements"] for device in baseline["devices"].values()), [231, 263])
        self.assertTrue(all(not key["down"] for device in baseline["devices"].values()
                            for key in device["keys"].values()))
        self.assertEqual(len(stream["records"]), 20)
        # Retained Actions timestamps use UTC; replay must not use the host zone.
        utc_clock = SimpleNamespace(fromtimestamp=lambda epoch: datetime.fromtimestamp(epoch, timezone.utc))
        with patch("hs274_hammerspoon.datetime", utc_clock):
            validate_consumer(evidence["hammerspoon"], evidence["capture"])
        opened = json.loads(evidence["interruption_output"].splitlines()[0])
        validate_successor(stream["opened"], opened)
        validate_interruption(evidence["interruption_output"], opened)
        frames = [json.loads(line) for line in evidence["stream_output"].splitlines()]
        pages = [index for index, frame in enumerate(frames) if frame["kind"] == "baseline"]
        self.assertEqual(len(pages), 8)
        for index in pages:
            with self.subTest(missing_page=index), self.assertRaises(ValueError):
                read_stream(encode(frames[:index] + frames[index + 1:]))
        with self.assertRaises(ValueError):
            read_stream(encode([frame for frame in frames if frame["kind"] != "baseline_ready"]))
        missing = copy.deepcopy(evidence["capture"])
        missing["records"] = missing["records"][:-1]
        with self.assertRaises(ValueError):
            validate_stream(evidence["stream_output"], missing)

    def test_successor_has_independent_baseline_and_exact_session_identity(self):
        previous = {"version": 1, "kind": "opened", "coverage": "fixture_only",
                    "incarnation": "868caf13-2110-4244-8fc2-12d490504a09", "lease": "2",
                    "baseline": {"version": 1, "boundary": "100", "rows": 2}}
        opened = dict(previous, lease="3", baseline={"version": 1, "boundary": "200", "rows": 3})
        validate_successor(previous, opened)
        for field, value in (("lease", "2"), ("lease", "4"), ("version", True),
                             ("incarnation", "968caf13-2110-4244-8fc2-12d490504a09"),
                             ("coverage", "all_devices")):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_successor(previous, dict(opened, **{field: value}))
        for baseline in ({"version": 1, "boundary": "100", "rows": 3},
                         {"version": 1, "boundary": "99", "rows": 3},
                         {"version": 1, "boundary": "200", "rows": 0}):
            with self.subTest(baseline=baseline), self.assertRaises(ValueError):
                validate_successor(previous, dict(opened, baseline=baseline))
        with self.assertRaises(ValueError):
            validate_successor(previous, {key: value for key, value in opened.items() if key != "baseline"})

    def test_paged_initial_state_preserves_cookies_and_empty_interfaces(self):
        capture, frames = fixture()
        opened = dict(frames[0], baseline={"version": 1, "boundary": "100", "rows": 4})
        first = dict(frames[0], kind="baseline", boundary="100", offset=0, next=2, total=4,
                     complete=False, rows=[{"kind": "device", "device": "41", "keyboard": True, "elements": 2},
                                           {"kind": "key", "device": "41", "usage": 224, "cookie": 24,
                                            "timestamp": "90", "down": False}])
        last = dict(first, offset=2, next=4, complete=True,
                    rows=[{"kind": "key", "device": "41", "usage": 224, "cookie": 289,
                           "timestamp": "95", "down": True},
                          {"kind": "device", "device": "42", "keyboard": False, "elements": 0}])
        ready = dict(frames[0], kind="baseline_ready")
        stream = [opened, first, last, ready, *frames[1:]]
        decoded = read_stream(encode(stream))
        self.assertEqual(decoded["records"], capture["records"])
        self.assertTrue(decoded["baseline"]["complete"])
        self.assertEqual(decoded["baseline"]["devices"][41]["keys"], {
            24: {"usage": 224, "timestamp": 90, "down": False},
            289: {"usage": 224, "timestamp": 95, "down": True}})
        self.assertEqual(decoded["baseline"]["devices"][42]["keys"], {})
        lost = dict(frames[0], kind="lost", reason="interrupted")
        self.assertEqual(validate_interruption(encode([opened, first, last, ready, lost]), opened)["terminal"], lost)
        with self.assertRaises(ValueError):
            validate_interruption(encode([opened, first, lost]), opened)
        with self.assertRaises(ValueError):
            validate_interruption(encode([*stream, lost]), opened)
        partial = read_stream(encode(stream[:2]))
        self.assertFalse(partial["baseline"]["complete"])
        self.assertEqual(partial["records"], [])
        for broken in ([opened, last, ready], [opened, first, first, last, ready],
                       [opened, first, ready], [opened, first, last, *frames[1:]],
                       [opened, first, last, ready, last]):
            with self.subTest(broken=broken), self.assertRaises(ValueError):
                read_stream(encode(broken))
        for field, value in (("cookie", 24), ("timestamp", "101"), ("device", "42"),
                             ("usage", 1), ("down", 1)):
            broken = copy.deepcopy(stream)
            broken[2]["rows"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                read_stream(encode(broken))
        for field, value in (("next", True), ("total", 5), ("complete", True), ("boundary", "99")):
            broken = copy.deepcopy(stream)
            broken[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                read_stream(encode(broken))

    def test_retained_native_cookies_match_the_stream_and_inventory(self):
        path = Path(__file__).parent / "fixtures" / "hs274-native-cookie-capture.json"
        evidence = json.loads(path.read_text(encoding="utf-8"))
        capture = evidence["capture"]
        stream = validate_stream(evidence["stream_output"], capture)
        self.assertEqual(stream["records"], capture["records"])
        self.assertEqual(len(stream["records"]), 20)
        self.assertTrue(all(row["has_cookie"] is True for row in stream["records"]))
        elements = {row["cookie"]: row for row in evidence["referenced_keyboard_elements"]}
        keys = [row for row in stream["records"] if row["page"] == 7 and 4 <= row["usage"] <= 255]
        self.assertEqual([(row["cookie"], row["usage"], row["value"]) for row in keys],
                         [(106, 41, 1), (106, 41, 0), (109, 44, 1), (109, 44, 0)])
        for row in keys:
            self.assertEqual(elements[row["cookie"]]["usage"], row["usage"])
        altered = copy.deepcopy(capture)
        altered["records"][2]["cookie"] = 109
        with self.assertRaisesRegex(ValueError, "differs"):
            validate_stream(evidence["stream_output"], altered)

    def test_element_cookies_are_retained_and_compared_with_the_independent_capture(self):
        capture, frames = fixture()
        capture["records"][0].update(has_cookie=True, cookie=24)
        frames[1]["records"][0].update(has_cookie=True, cookie=24)
        self.assertEqual(validate_stream(encode(frames), capture)["records"], capture["records"])
        for change in ({"cookie": 289}, {"has_cookie": False, "cookie": 0}):
            broken = copy.deepcopy(frames)
            broken[1]["records"][0].update(change)
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "differs"):
                validate_stream(encode(broken), capture)
        for field in ("cookie", "has_cookie"):
            broken = copy.deepcopy(frames)
            del broken[1]["records"][0][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                read_stream(encode(broken))
        for change in ({"cookie": -1}, {"cookie": 1 << 32}, {"cookie": True},
                       {"has_cookie": 1}, {"has_cookie": False, "cookie": 24}):
            broken = copy.deepcopy(frames)
            broken[1]["records"][0].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                read_stream(encode(broken))

    def test_native_consumer_owns_acknowledgements_without_python_input(self):
        remap = remap_module()
        _, frames = fixture()
        with tempfile.TemporaryDirectory(prefix="hs274-native-ack-") as directory:
            path = Path(directory) / "stream"
            path.write_text(encode(frames), encoding="utf-8")
            process = SimpleNamespace(poll=lambda: None)
            actual = remap.wait_stream(path, process, lambda stream: True, 1, acknowledge=False)
            self.assertEqual(actual, read_stream(encode(frames)))

    def test_fixture_receiver_acknowledges_baseline_before_raw_input(self):
        remap = remap_module()
        capture, frames = fixture()
        opened = dict(frames[0], baseline={"version": 1, "boundary": "100", "rows": 4})
        stages = [{"opened": opened, "records": [],
                   "baseline": {"received_rows": cursor, "complete": complete}}
                  for cursor, complete in ((0, False), (2, False), (2, False), (4, False), (4, True))]
        stages.append(dict(stages[-1], records=capture["records"]))
        client = SimpleNamespace(poll=lambda: None, stdin=io.BytesIO(), capture_ack=None)
        path = SimpleNamespace(read_text=lambda **kwargs: "validated by mocked reader")
        seen = []
        with patch.object(remap, "read_stream", side_effect=stages), patch.object(remap.time, "sleep"):
            actual = remap.wait_stream(path, client, lambda stream: seen.append(stream) or bool(stream["records"]), 1)
        receipts = [json.loads(line) for line in client.stdin.getvalue().splitlines()]
        identity = {"version": 1, "incarnation": opened["incarnation"], "lease": opened["lease"]}
        self.assertEqual(receipts, [dict(identity, ack="0"), dict(identity, baseline_ack="2"),
                                   dict(identity, baseline_ack="4"),
                                   dict(identity, ack=str(capture["records"][-1]["sequence"]))])
        self.assertEqual(seen, stages[-2:])
        self.assertEqual(actual, stages[-1])

    def test_receiver_acknowledges_only_validated_complete_frames_once(self):
        remap = remap_module()
        _, frames = fixture()
        with tempfile.TemporaryDirectory(prefix="hs274-ack-") as directory:
            path = Path(directory) / "stream"
            client = SimpleNamespace(poll=lambda: None, stdin=io.BytesIO(), capture_ack=None)
            path.write_text(encode(frames[:1]), encoding="utf-8")
            remap.wait_stream(path, client, lambda stream: True, 1)
            expected = {"version": 1, "incarnation": frames[0]["incarnation"], "lease": frames[0]["lease"], "ack": "0"}
            self.assertTrue(client.stdin.getvalue(), "Validated opening must be acknowledged to the producer")
            self.assertEqual(json.loads(client.stdin.getvalue()), expected)
            first = client.stdin.getvalue()
            remap.wait_stream(path, client, lambda stream: True, 1)
            self.assertEqual(client.stdin.getvalue(), first)
            path.write_text(encode(frames[:1]) + json.dumps(frames[1])[:-1], encoding="utf-8")
            remap.wait_stream(path, client, lambda stream: True, 1)
            self.assertEqual(client.stdin.getvalue(), first)
            path.write_text(encode(frames), encoding="utf-8")
            remap.wait_stream(path, client, lambda stream: True, 1)
            receipts = client.stdin.getvalue().splitlines()
            self.assertEqual(len(receipts), 2)
            self.assertEqual(json.loads(receipts[-1]), dict(expected, ack=frames[-1]["records"][-1]["sequence"]))
            accepted = client.stdin.getvalue()
            malformed = copy.deepcopy(frames)
            malformed[-1]["records"][-1]["sequence"] = "999"
            path.write_text(encode(malformed), encoding="utf-8")
            with self.assertRaises(ValueError):
                remap.wait_stream(path, client, lambda stream: True, 1)
            self.assertEqual(client.stdin.getvalue(), accepted)

    def test_receiver_does_not_commit_acknowledgement_when_input_write_fails(self):
        remap = remap_module()
        _, frames = fixture()
        with tempfile.TemporaryDirectory(prefix="hs274-ack-write-") as directory:
            path = Path(directory) / "stream"
            path.write_text(encode(frames[:1]), encoding="utf-8")
            sink = io.BytesIO()
            sink.close()
            client = SimpleNamespace(poll=lambda: None, stdin=sink, capture_ack=None)
            with self.assertRaises(ValueError):
                remap.wait_stream(path, client, lambda stream: True, 1)
            self.assertIsNone(client.capture_ack)

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
        for field in ("value", "usage"):
            malformed = copy.deepcopy(stream)
            malformed["records"][-1][field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                complete(malformed)
        missing = copy.deepcopy(stream)
        missing["records"][-1]["device"] += 1
        self.assertFalse(complete(missing))
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
                client = SimpleNamespace(poll=lambda: None, returncode=None, stdin=io.BytesIO(), capture_ack=None)
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

    def test_interleaved_devices_preserve_global_evidence_and_exact_fixture_values(self):
        capture, frames = fixture()
        device = capture["records"][0]["device"]
        rows = []
        for row in [row for frame in frames[1:] for row in frame["records"]]:
            rows.extend([dict(row, device=str(device + 1)), dict(row)])
        for index, row in enumerate(rows, 1):
            row["sequence"] = str(index)
        interleaved = [frames[0], dict(frames[0], kind="batch", records=rows)]
        result = validate_stream(encode(interleaved), capture)
        self.assertEqual(len(result["records"]), 40)
        self.assertEqual([row["sequence"] for row in result["records"]], list(range(1, 41)))
        complete = fixture_drain(device)
        self.assertFalse(complete(dict(result, records=result["records"][:-1])))
        self.assertTrue(complete(result))
        for index, field, value in ((0, "sequence", "2"), (0, "has_usage", 1),
                                    (1, "value", "999"), (39, "device", str(device + 1))):
            broken = copy.deepcopy(interleaved)
            broken[1]["records"][index][field] = value
            with self.subTest(index=index, field=field), self.assertRaises(ValueError):
                validate_stream(encode(broken), capture)
        extra = copy.deepcopy(interleaved)
        extra[1]["records"].append(dict(rows[-1], sequence="41"))
        with self.assertRaises(ValueError):
            validate_stream(encode(extra), capture)
        with self.assertRaises(ValueError):
            complete(read_stream(encode(extra)))

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
