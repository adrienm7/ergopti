# tools/diagnostics/hs274_baseline_v2_test.py
"""Independent version-2 row and strict historical-replay controls."""

import json
import unittest

from hs274_baseline_frames import BaselineFrames
from hs274_stream import read_stream


IDENTITY = {
    "version": 1,
    "coverage": "fixture_only",
    "incarnation": "12345678-1234-1234-1234-123456789abc",
    "lease": "9",
}


def fixture():
    """Handwritten identities, including same-usage cookies and both vendor pages."""
    rows = [
        {"kind": "device", "device": "41", "keyboard": True, "keyboard_type": "iso", "elements": 2},
        {
            "kind": "key",
            "device": "41",
            "page": 7,
            "usage": 44,
            "cookie": 1,
            "timestamp": "90",
            "down": True,
        },
        {
            "kind": "key",
            "device": "41",
            "page": 7,
            "usage": 44,
            "cookie": 2,
            "timestamp": "80",
            "down": False,
        },
        {
            "kind": "device",
            "device": "42",
            "keyboard": False,
            "keyboard_type": "none",
            "elements": 3,
        },
        {
            "kind": "key",
            "device": "42",
            "page": 12,
            "usage": 3,
            "cookie": 1,
            "timestamp": "95",
            "down": True,
        },
        {
            "kind": "key",
            "device": "42",
            "page": 255,
            "usage": 3,
            "cookie": 2,
            "timestamp": "96",
            "down": True,
        },
        {
            "kind": "key",
            "device": "42",
            "page": 65281,
            "usage": 3,
            "cookie": 3,
            "timestamp": "97",
            "down": True,
        },
    ]
    opening = dict(IDENTITY, kind="opened", baseline={"version": 2, "boundary": "100", "rows": 7})
    first = dict(
        IDENTITY,
        kind="baseline",
        boundary="100",
        offset=0,
        next=4,
        total=7,
        complete=False,
        rows=rows[:4],
    )
    last = dict(
        IDENTITY,
        kind="baseline",
        boundary="100",
        offset=4,
        next=7,
        total=7,
        complete=True,
        rows=rows[4:],
    )
    return [opening, first, last, dict(IDENTITY, kind="baseline_ready")]


def encoded(frames):
    return "".join(json.dumps(frame) + "\n" for frame in frames)


class BaselineV2Tests(unittest.TestCase):
    def test_exact_multipage_identity_and_inherited_state(self):
        result = read_stream(encoded(fixture()))["baseline"]
        self.assertTrue(result["complete"])
        self.assertEqual(result["devices"][41]["keyboard_type"], "iso")
        self.assertEqual(
            result["devices"][41]["keys"][1],
            {"page": 7, "usage": 44, "timestamp": 90, "down": True},
        )
        self.assertFalse(result["devices"][41]["keys"][2]["down"])
        self.assertEqual(
            [key["page"] for key in result["devices"][42]["keys"].values()], [12, 255, 65281]
        )
        self.assertTrue(all(key["down"] for key in result["devices"][42]["keys"].values()))

    def test_strict_descriptor_does_not_admit_old_baseline(self):
        with self.assertRaises(ValueError):
            BaselineFrames({"version": 1, "boundary": "100", "rows": 1})

    def test_strict_stream_does_not_admit_absent_baseline(self):
        with self.assertRaises(ValueError):
            read_stream(encoded([dict(IDENTITY, kind="opened")]))

    def test_explicit_historical_replay_preserves_frozen_v1_shape(self):
        old = [
            dict(IDENTITY, kind="opened", baseline={"version": 1, "boundary": "100", "rows": 2}),
            dict(
                IDENTITY,
                kind="baseline",
                boundary="100",
                offset=0,
                next=2,
                total=2,
                complete=True,
                rows=[
                    {"kind": "device", "device": "41", "keyboard": True, "elements": 1},
                    {
                        "kind": "key",
                        "device": "41",
                        "usage": 44,
                        "cookie": 109,
                        "timestamp": "90",
                        "down": True,
                    },
                ],
            ),
            dict(IDENTITY, kind="baseline_ready"),
        ]
        with self.assertRaises(ValueError):
            read_stream(encoded(old))
        result = read_stream(encoded(old), historical_baseline=True)["baseline"]
        self.assertEqual(
            result["devices"][41]["keys"], {109: {"usage": 44, "timestamp": 90, "down": True}}
        )
        self.assertNotIn("keyboard_type", result["devices"][41])

    def test_missing_unknown_and_cross_inventory_type_refused(self):
        for marker_index, field, value in (
            (0, "keyboard_type", "none"),
            (0, "keyboard_type", "unknown"),
            (3, "keyboard_type", "ansi"),
            (3, "keyboard", True),
        ):
            frames = fixture()
            frames[1]["rows"][marker_index][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                read_stream(encoded(frames))
        frames = fixture()
        del frames[1]["rows"][0]["keyboard_type"]
        with self.assertRaises(ValueError):
            read_stream(encoded(frames))

    def test_descriptor_types_and_wrong_version_refused(self):
        for version in (True, 0, 1, 3, "2"):
            frames = fixture()
            frames[0]["baseline"]["version"] = version
            with self.subTest(version=version), self.assertRaises(ValueError):
                read_stream(encoded(frames))

    def test_page_usage_value_and_duplicate_cookie_refused(self):
        for field, value in (
            ("page", 0),
            ("page", 8),
            ("page", True),
            ("usage", 0),
            ("usage", 256),
            ("down", 1),
            ("timestamp", "101"),
            ("cookie", 2),
        ):
            frames = fixture()
            frames[1]["rows"][1][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                read_stream(encoded(frames))
        for page in (7, 12, 255, 65281):
            frames = fixture()
            frames[2]["rows"][0].update(page=page, usage=65536)
            with self.subTest(page=page), self.assertRaises(ValueError):
                read_stream(encoded(frames))

    def test_page7_error_only_and_inventory_derived_keyboard_flag(self):
        frames = fixture()
        frames[1]["rows"][1]["usage"] = 3
        with self.assertRaises(ValueError):
            read_stream(encoded(frames))
        frames = fixture()
        frames[1]["rows"][1]["page"] = 12
        frames[1]["rows"][2]["page"] = 255
        with self.assertRaises(ValueError):
            read_stream(encoded(frames))
        frames = fixture()
        frames[2]["rows"][0]["page"] = 7
        with self.assertRaises(ValueError):
            read_stream(encoded(frames))

    def test_partial_evidence_never_reports_complete(self):
        frames = fixture()
        result = read_stream(encoded(frames[:2]))["baseline"]
        self.assertFalse(result["complete"])
        self.assertEqual(result["received_rows"], 4)
        with self.assertRaises(ValueError):
            read_stream(encoded(frames[:-1] + [dict(IDENTITY, kind="batch", records=[])]))


if __name__ == "__main__":
    unittest.main()
