"""The layout the per-layer composer compiles converts to XKB.

The shared composer corpus (_shared/tests/corpus/layouts/composer) is a
composition of QWERTY, AZERTY, Ergopti and Ergo-L layers compiled by the
composer model into one .keylayout. The Linux converter reads it like a
registry layout: the seven XKB levels follow the composer's modifierMap, the
single XKB shortcuts level is the composer's Win/Cmd keyMap, and the dead keys
of the source layouts compose the letters of the other layers.
"""

from __future__ import annotations

import json
import unittest

from support import KEYCODES_PATH, STATIC_DIR, keylayout_to_xkb

CORPUS_DIR = STATIC_DIR / "ergopti_plus" / "_shared" / "tests" / "corpus" / "layouts" / "composer"

# keyMap index per XKB level (base, caps, shift, caps+shift, command, option,
# shift+option), read off the composer's modifierMap by hand
# (docs/layout-composer.md).
COMPOSER_LEVEL_INDICES = [0, 2, 1, 1, 5, 3, 4]
KEY_Q = 12  # macOS code of the key right of Tab under the iso convention
KEY_BRACKET_LEFT = 33


def corpus_text() -> str:
    return (CORPUS_DIR / "composed.keylayout").read_text(encoding="utf-8")


class ComposerCorpusTests(unittest.TestCase):
    def setUp(self):
        self.declaration = json.loads((CORPUS_DIR / "composition.json").read_text(encoding="utf-8"))
        self.layout = keylayout_to_xkb.parse_keylayout(corpus_text())

    def test_the_xkb_levels_follow_the_composer_modifier_map(self):
        indices = [self.layout.key_map_index(mods) for mods in keylayout_to_xkb.XKB_LEVELS]
        self.assertEqual(indices, COMPOSER_LEVEL_INDICES)

    def test_each_level_types_the_cell_of_its_layer(self):
        expected = {0: "q", 1: "A", 2: "`"}
        texts = {}
        for level, index in enumerate(COMPOSER_LEVEL_INDICES):
            resolved = keylayout_to_xkb.resolve(self.layout, index, KEY_Q)
            texts[level] = resolved.text
        self.assertEqual(texts[0], expected[0], "base is QWERTY")
        self.assertEqual(texts[1], "A", "caps takes the Shift cell of a letter")
        self.assertEqual(texts[2], "A", "shift is AZERTY")
        self.assertEqual(texts[4], "q", "the single shortcuts level is the Win/Cmd layer")
        self.assertEqual(texts[5], expected[2], "AltGr is Ergopti")

    def test_the_whole_corpus_converts_with_dead_keys_composing_other_layers(self):
        entry_keycodes = keylayout_to_xkb.load_keycodes(
            KEYCODES_PATH, self.declaration["keycode_convention"]
        )
        result = keylayout_to_xkb.convert(
            corpus_text(),
            entry_keycodes,
            "composed",
            self.declaration["name"],
            keylayout_to_xkb.XkbHints(),
        )
        self.assertIn("composed", result.symbols_text)
        # The AZERTY diaeresis and the Ergo-L circumflex compose the QWERTY letter e.
        self.assertIn("ë", result.compose_text)
        self.assertIn("ê", result.compose_text)


if __name__ == "__main__":
    unittest.main()
