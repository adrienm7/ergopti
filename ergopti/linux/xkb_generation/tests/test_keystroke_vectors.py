"""The XKB conversion types what the shared keystroke vectors say.

_shared/tests/corpus/layouts/keylayout_vectors.json lists what typing on a
registry layout produces, read by hand from its .keylayout. The Windows
emulation replays every vector; this test replays them against the Linux
conversion, so both readers of the same .keylayout are pinned to the same
answers:

- a single key types, at the XKB level of its modifiers, the keysym of the
  expected character (or the keysym the conversion borrowed for a longer
  output), NoSymbol when it types nothing;
- a dead-key sequence is the Compose sequence of the keys' keysyms;
- a shortcut vector is the key's Command level (the fifth XKB level).

Two vector kinds describe behaviour XKB does not have, and are skipped by id
with the reason below.
"""

from __future__ import annotations

import json
import re
import unittest

from support import KEYCODES_PATH, STATIC_DIR, convert_registry_layout, keylayout_to_xkb
from test_registry_conversion import parse_compose

VECTORS_PATH = (
    STATIC_DIR
    / "ergopti_plus"
    / "_shared"
    / "tests"
    / "corpus"
    / "layouts"
    / "keylayout_vectors.json"
)

# XKB level index of each modifier set of a vector (keylayout_to_xkb.XKB_LEVELS order).
LEVELS = {
    (): 0,
    ("caps",): 1,
    ("shift",): 2,
    ("caps", "shift"): 3,
    ("altgr",): 5,
    ("altgr", "shift"): 6,
}
COMMAND_LEVEL = 4

SKIPPED = {
    # macOS types a dead key's terminator, then the next key; XCompose cancels
    # a sequence that has no entry instead.
    "ergol_one_dead_key_terminator": "XCompose has no terminators",
    # A shortcut on a dead key keeps the physical key on Windows; XKB has no
    # shortcut level distinct from the dead key it carries.
    "ergol_shortcut_dead_key": "no XKB counterpart",
    # KNOWN LINUX GAP, frozen by the golden test: the committed Ergopti files
    # name a dead key pressed inside a dead-key state after the character its
    # action is named after (<dead_circumflex> <diaeresis> : "/"), but that key
    # types dead_diaeresis, so the sequence cannot be typed. ^ ^ still works
    # through the system table the files include; ^ then ¨ does not.
    "ergopti_dead_circumflex_twice": "Ergopti's golden XCompose, see above",
    "ergopti_chained_dead_keys": "Ergopti's golden XCompose, see above",
}


def load_vectors() -> list:
    return json.loads(VECTORS_PATH.read_text(encoding="utf-8"))["vectors"]


def xkb_names() -> dict:
    """AutoHotkey scan code -> XKB key name, from the shared keycode table."""
    table = json.loads(KEYCODES_PATH.read_text(encoding="utf-8"))
    return {key["ahk"]: key["xkb"] for key in table["keys"]}


def parse_press(press: str):
    parts = press.split(" ")
    return parts[-1], tuple(sorted(parts[:-1]))


class KeystrokeVectorReplay(unittest.TestCase):
    """Replays the shared vectors against the conversion of their layout."""

    @classmethod
    def setUpClass(cls):
        cls.vectors = load_vectors()
        cls.seeds = json.loads(VECTORS_PATH.read_text(encoding="utf-8"))["dead_reset_seeds"]
        cls.names = xkb_names()
        cls.keysyms = keylayout_to_xkb.load_keysym_table()
        cls.conversions = {}
        cls.compose = {}
        for layout in sorted({vector["layout"] for vector in cls.vectors + cls.seeds}):
            conversion = convert_registry_layout(layout)
            cls.conversions[layout] = conversion
            cls.compose[layout] = parse_compose(conversion.compose_text)

    def keysym_for_text(self, layout: str, text: str) -> str:
        """Keysym the conversion must use for a typed text."""
        borrowed = self.conversions[layout].borrowed
        if text in borrowed:
            return borrowed[text]
        self.assertEqual(
            len(text), 1, "a multi-character output needs a borrowed keysym: %r" % text
        )
        return self.keysyms.get(text) or keylayout_to_xkb.unicode_keysym(text)

    def key_keysym(self, layout: str, press: str) -> str:
        sc, mods = parse_press(press)
        self.assertIn(mods, LEVELS, "unknown modifiers in vector press %r" % press)
        return self.conversions[layout].key_symbols[self.names[sc]][LEVELS[mods]]

    def test_windows_reset_seeds_are_real_dead_keys_on_linux(self):
        self.assertGreaterEqual(len(self.seeds), 5)
        self.assertEqual(
            {seed["layout"] for seed in self.seeds}, {"ergol", "ergopti", "ergopti_plus"}
        )
        for seed in self.seeds:
            with self.subTest(seed=seed):
                symbol = self.key_keysym(seed["layout"], seed["press"])
                self.assertIn(
                    symbol,
                    self.conversions[seed["layout"]].dead_triggers.values(),
                    f"{seed}: {symbol} is not a dead-key trigger",
                )

    def test_every_vector_is_replayed_or_skipped_by_name(self):
        ids = {vector["id"] for vector in self.vectors}
        self.assertGreaterEqual(len(ids), 30)
        self.assertEqual(set(SKIPPED) - ids, set(), "a skip names a vector that no longer exists")

    def test_single_keys_type_the_vector_output(self):
        replayed = 0
        for vector in self.vectors:
            if vector["id"] in SKIPPED or "press" not in vector or len(vector["press"]) != 1:
                continue
            with self.subTest(vector=vector["id"]):
                keysym = self.key_keysym(vector["layout"], vector["press"][0])
                if vector["types"] == "":
                    self.assertEqual(keysym, "NoSymbol")
                else:
                    self.assertEqual(
                        keysym, self.keysym_for_text(vector["layout"], vector["types"])
                    )
                replayed += 1
        self.assertGreaterEqual(replayed, 20)

    def test_dead_key_sequences_are_compose_sequences(self):
        replayed = 0
        for vector in self.vectors:
            if vector["id"] in SKIPPED or "press" not in vector or len(vector["press"]) < 2:
                continue
            with self.subTest(vector=vector["id"]):
                layout = vector["layout"]
                sequence = tuple(self.key_keysym(layout, press) for press in vector["press"])
                self.assertEqual(
                    self.compose[layout].get(sequence),
                    vector["types"],
                    "Compose sequence %r" % (sequence,),
                )
                replayed += 1
        self.assertGreaterEqual(replayed, 6)

    def test_shortcuts_use_the_command_level(self):
        replayed = 0
        for vector in self.vectors:
            if vector["id"] in SKIPPED or "shortcut" not in vector:
                continue
            with self.subTest(vector=vector["id"]):
                layout = vector["layout"]
                keysym = self.conversions[layout].key_symbols[self.names[vector["shortcut"]]][
                    COMMAND_LEVEL
                ]
                self.assertEqual(keysym, self.keysym_for_text(layout, vector["sends"]))
                replayed += 1
        self.assertGreaterEqual(replayed, 3)


if __name__ == "__main__":
    unittest.main()
