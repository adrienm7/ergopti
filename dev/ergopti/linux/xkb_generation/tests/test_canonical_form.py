"""The canonical parsed form (schema 1) the converter shares with the Lua parser.

The shared corpus (_shared/tests/corpus/keylayout) pins what every parser must
produce for a set of hand-checked fixtures and for the composer layout; the macOS
and Linux Lua suites replay it against _shared/lua/layouts/keylayout.lua. This
module replays it against this converter's parser and proves the converter
reads the canonical form: converting a layout through the form gives the same
XKB and XCompose text as converting its .keylayout directly, for every layout of
the registry.
"""

from __future__ import annotations

import json
import unittest

from support import (
    KEYCODES_PATH,
    STATIC_DIR,
    keylayout_to_xkb,
    registry_entries,
    registry_keylayout,
)

CORPUS_DIR = STATIC_DIR / "ergopti_plus" / "_shared" / "tests" / "corpus" / "keylayout"
COMPOSER_DIR = STATIC_DIR / "ergopti_plus" / "_shared" / "tests" / "corpus" / "layouts" / "composer"


def through_canonical(text: str):
    """The Keylayout read back from its own canonical form, through JSON."""
    form = keylayout_to_xkb.parse_keylayout(text).to_canonical()
    return keylayout_to_xkb.Keylayout.from_canonical(json.loads(json.dumps(form)))


class CanonicalCorpusTests(unittest.TestCase):
    def test_every_edge_fixture_parses_to_its_canonical_form_or_is_refused(self):
        corpus = json.loads((CORPUS_DIR / "edge_cases.json").read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(corpus["vectors"]), 6)
        for vector in corpus["vectors"]:
            with self.subTest(vector["name"]):
                if vector.get("error"):
                    with self.assertRaises(keylayout_to_xkb.KeylayoutError):
                        keylayout_to_xkb.parse_keylayout(vector["keylayout"])
                else:
                    parsed = keylayout_to_xkb.parse_keylayout(vector["keylayout"])
                    self.assertEqual(parsed.to_canonical(), vector["canonical"])

    def test_the_composer_layout_parses_to_the_pinned_canonical_form(self):
        text = (COMPOSER_DIR / "composed.keylayout").read_text(encoding="utf-8")
        pinned = json.loads((CORPUS_DIR / "composed.canonical.json").read_text(encoding="utf-8"))[
            "canonical"
        ]
        self.assertEqual(keylayout_to_xkb.parse_keylayout(text).to_canonical(), pinned)

    def test_a_form_of_another_schema_or_without_its_parts_is_refused(self):
        with self.assertRaises(keylayout_to_xkb.KeylayoutError):
            keylayout_to_xkb.Keylayout.from_canonical({"schema": 2})
        with self.assertRaises(keylayout_to_xkb.KeylayoutError):
            keylayout_to_xkb.Keylayout.from_canonical({"schema": 1, "name": "x"})


class CanonicalConversionTests(unittest.TestCase):
    def test_every_registry_layout_converts_to_the_same_files_through_the_canonical_form(self):
        for entry in registry_entries():
            with self.subTest(entry["id"]):
                text = registry_keylayout(entry["id"])
                keycodes = keylayout_to_xkb.load_keycodes(
                    KEYCODES_PATH, entry["keycode_convention"]
                )
                hints = keylayout_to_xkb.XkbHints.from_entry(entry)
                direct = keylayout_to_xkb.convert(text, keycodes, entry["id"], entry["name"], hints)
                canonical = keylayout_to_xkb.convert_layout(
                    through_canonical(text), keycodes, entry["id"], entry["name"], hints
                )
                self.assertEqual(canonical.symbols_text, direct.symbols_text)
                self.assertEqual(canonical.compose_text, direct.compose_text)


if __name__ == "__main__":
    unittest.main()
