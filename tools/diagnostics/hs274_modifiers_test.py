# tools/diagnostics/hs274_modifiers_test.py
"""Reject lost physical modifier edges before native acquisition is attempted."""

import copy
import json
import unittest

from hs274_capture import MARKER
from hs274_modifiers import KEYCODES, modifier_drain, validate_modifier_capture, validate_modifier_output
from hs274_stream_test import fixture


def modifier_fixture():
    """Use synthetic modifier edges and the retained native trailing pair."""
    capture, _ = fixture()
    template = capture["records"][2]
    prefix = [dict(template, usage=usage, has_cookie=True, cookie=usage, value=value)
              for usage in range(224, 232) for value in (1, 0)]
    capture["records"] = prefix + capture["records"]
    for sequence, row in enumerate(capture["records"], 1):
        row["sequence"] = sequence
        row["timestamp"] = sequence
    capture["seen"] = len(capture["records"])
    return capture


class ModifierTests(unittest.TestCase):
    def test_native_modifier_flags_require_both_edges_and_exact_sides(self):
        pairs = ((59, 262144), (56, 131072), (58, 524288), (55, 1048576),
                 (62, 262144), (60, 131072), (61, 524288), (54, 1048576))
        events = [{"type": 12, "keycode": code, "flags": flags}
                  for code, mask in pairs for flags in (mask, 0)]
        events += [{"type": kind, "keycode": 49} for kind in (10, 11, 10, 11)]
        native = {"events": events, "reports_queued": 20, "modifier_pairs_observed": True}
        validate_modifier_output(native)
        for index in range(16):
            broken = copy.deepcopy(native)
            broken["events"][index]["flags"] = 0 if index % 2 == 0 else pairs[index // 2][1]
            with self.subTest(index=index), self.assertRaises(ValueError):
                validate_modifier_output(broken)

    def test_all_sides_and_complete_collision_tail_are_required(self):
        capture = modifier_fixture()
        device = capture["records"][0]["device"]
        output = MARKER + json.dumps(capture) + "\n"
        self.assertEqual(validate_modifier_capture(output, device), capture)
        self.assertEqual(KEYCODES[225], 56)
        self.assertEqual(KEYCODES[229], 60)
        drain = modifier_drain(device)
        for count in range(len(capture["records"])):
            self.assertFalse(drain({"records": capture["records"][:count]}))
        self.assertTrue(drain(capture))
        for index in range(16):
            for duplicate in (False, True):
                broken = copy.deepcopy(capture)
                if duplicate:
                    broken["records"].insert(index, dict(broken["records"][index], cookie=999))
                else:
                    broken["records"].pop(index)
                for sequence, row in enumerate(broken["records"], 1):
                    row["sequence"] = sequence
                broken["seen"] = len(broken["records"])
                with self.subTest(index=index, duplicate=duplicate), self.assertRaises(ValueError):
                    validate_modifier_capture(MARKER + json.dumps(broken) + "\n", device)
                with self.subTest(drain=index, duplicate=duplicate), self.assertRaises(ValueError):
                    drain(broken)


if __name__ == "__main__":
    unittest.main()
