# tools/diagnostics/hs274_repeat_test.py
"""Reject repeat receipts which could be produced by repeated physical taps."""

import copy
import unittest

from hs274_repeat import validate_repeat_output


class RepeatTests(unittest.TestCase):
    def test_os_repeat_requires_initial_press_repeats_and_final_release(self):
        native = {"repeat_observed": True, "reports_queued": 4, "space_pair_observed": True,
                  "events": [{"type": kind, "keycode": 49, "autorepeat": repeated}
                             for kind, repeated in ((10, 0), (11, 0), (10, 0), (10, 1), (10, 1), (11, 0))]}
        validate_repeat_output(native)
        for index in range(len(native["events"])):
            for field, value in (("type", 12), ("keycode", 53), ("autorepeat", None)):
                broken = copy.deepcopy(native)
                broken["events"][index][field] = value
                with self.subTest(index=index, field=field), self.assertRaises(ValueError):
                    validate_repeat_output(broken)
        for field, value in (("repeat_observed", False), ("reports_queued", 6), ("space_pair_observed", False)):
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_repeat_output(dict(native, **{field: value}))
        taps = copy.deepcopy(native)
        for event in taps["events"]:
            event["autorepeat"] = 0
        with self.assertRaisesRegex(ValueError, "repeated output"):
            validate_repeat_output(taps)
        for count in range(6):
            with self.subTest(prefix=count), self.assertRaises(ValueError):
                validate_repeat_output(dict(native, events=native["events"][:count]))


if __name__ == "__main__":
    unittest.main()
