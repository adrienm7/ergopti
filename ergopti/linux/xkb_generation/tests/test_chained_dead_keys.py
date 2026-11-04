"""A key pressed inside a dead-key state is composed from the keysym it sends.

The shared conversion vectors (_shared/tests/corpus/keylayout/
xkb_conversion_vectors.json) hold a hand-written layout shaped like Bépo's
chained dead keys, which the converter used to get wrong in three ways: a dead
key pressed inside a dead state (^ ^, ^ then ¨) was composed from the character
it types alone instead of its dead keysym, so the sequence could not be typed;
a plain "^" and the circumflex dead key collided on one sequence inside a third
dead key; and an action whose one-character id is not what it types was
composed from its id. The expected sequences below are written by hand from the
fixture, not taken from the converter, and the Lua converter replays the same
vectors (_shared/lua/test/xkb_converter_contract.lua).
"""

from __future__ import annotations

import json
import unittest

from support import KEYCODES_PATH, STATIC_DIR, keylayout_to_xkb
from test_registry_conversion import parse_compose

VECTORS_PATH = (
    STATIC_DIR
    / "ergopti_plus"
    / "_shared"
    / "tests"
    / "corpus"
    / "keylayout"
    / "xkb_conversion_vectors.json"
)
CHAINED_LAYOUT_ID = "chained"

# What macOS types for each sequence of the fixture, by the keysym each key
# sends on Linux: the circumflex key sends dead_circumflex, the diaeresis key
# dead_diaeresis, the science key the keysym of its terminator (infinity), the
# "☭" key what it types (⚠, U26A0) and the plain "^" key asciicircum.
EXPECTED_SEQUENCES = {
    ("dead_circumflex", "dead_circumflex"): "^",
    ("dead_circumflex", "dead_diaeresis"): "/",
    ("dead_circumflex", "a"): "â",
    ("dead_diaeresis", "dead_diaeresis"): "¨",
    ("dead_diaeresis", "dead_circumflex", "a"): "ǟ",
    ("infinity", "asciicircum"): "⃗",
    ("infinity", "dead_circumflex"): "→",
    ("infinity", "U26A0"): "⃕",
}
# The sequences the old converter wrote instead: nobody can type them.
UNTYPABLE_SEQUENCES = {
    ("dead_circumflex", "asciicircum"),
    ("dead_circumflex", "diaeresis"),
    ("dead_diaeresis", "diaeresis"),
    ("infinity", "U262D"),
}


def load_vectors() -> list:
    return json.loads(VECTORS_PATH.read_text(encoding="utf-8"))["vectors"]


def convert_vector(vector: dict):
    return keylayout_to_xkb.convert(
        vector["keylayout"],
        keylayout_to_xkb.load_keycodes(KEYCODES_PATH, vector["convention"]),
        vector["layout_id"],
        vector["display_name"],
        keylayout_to_xkb.XkbHints.from_entry({"xkb": vector.get("hints", {})}),
    )


class ChainedDeadKeyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vector = next(v for v in load_vectors() if v["layout_id"] == CHAINED_LAYOUT_ID)
        cls.result = convert_vector(cls.vector)
        cls.compose = parse_compose(cls.result.compose_text)

    def test_the_keys_send_the_keysyms_the_expectations_name(self):
        names = {code: xkb for xkb, code in keylayout_to_xkb.load_keycodes(KEYCODES_PATH, "iso")}
        base = {code: self.result.key_symbols[names[code]][0] for code in (0, 2, 3, 4, 5, 8)}
        self.assertEqual(
            base,
            {
                0: "a",
                8: "dead_circumflex",
                2: "dead_diaeresis",
                3: "infinity",
                4: "U26A0",
                5: "asciicircum",
            },
        )

    def test_every_sequence_types_what_macos_types(self):
        for sequence, output in EXPECTED_SEQUENCES.items():
            with self.subTest(sequence=sequence):
                self.assertEqual(self.compose.get(sequence), output)

    def test_no_sequence_names_a_keysym_no_key_sends(self):
        self.assertEqual(UNTYPABLE_SEQUENCES & set(self.compose), set())

    def test_a_plain_key_and_a_dead_key_with_one_base_keysym_do_not_collide(self):
        self.assertEqual(self.result.conflicts, [])


class SharedVectorTests(unittest.TestCase):
    def test_every_shared_vector_holds_this_converters_files(self):
        """The Lua contract compares its output with these, so they must be ours."""
        vectors = load_vectors()
        self.assertGreaterEqual(len(vectors), 2)
        for vector in vectors:
            with self.subTest(vector=vector["name"]):
                result = convert_vector(vector)
                self.assertEqual(result.symbols_text, vector["symbols"])
                self.assertEqual(result.compose_text, vector["compose"])


if __name__ == "__main__":
    unittest.main()
