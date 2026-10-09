"""Unit tests of the .keylayout reader and the conversion rules.

Synthetic layouts keep each rule visible: the modifierMap decides the level,
baseMapSet inheritance fills missing keys, chained dead keys become longer
Compose sequences, and two keys typing one keysym inside a dead-key state are
reported instead of silently dropping one output.
"""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

from support import INDEX_PATH, KEYCODES_PATH, keylayout_to_xkb, registry_keylayout

HEADER = '<?xml version="1.1" encoding="UTF-8"?>\n<!DOCTYPE keyboard SYSTEM "file://localhost/System/Library/DTDs/KeyboardLayout.dtd">\n'


def synthetic(
    key_maps: str, actions: str = "", terminators: str = "", modifier_map: str = ""
) -> str:
    modifiers = modifier_map or (
        '<modifierMap id="m" defaultIndex="0">'
        '<keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect>'
        '<keyMapSelect mapIndex="1"><modifier keys="anyShift caps?"/></keyMapSelect>'
        '<keyMapSelect mapIndex="2"><modifier keys="anyOption"/></keyMapSelect>'
        "</modifierMap>"
    )
    return (
        HEADER
        + '<keyboard group="0" id="1" name="Synthetic" maxout="1">'
        + '<layouts><layout first="0" last="17" mapSet="s" modifiers="m"/></layouts>'
        + modifiers
        + '<keyMapSet id="s">'
        + key_maps
        + "</keyMapSet>"
        + "<actions>"
        + actions
        + "</actions>"
        + "<terminators>"
        + terminators
        + "</terminators>"
        + "</keyboard>"
    )


# Keycode table limited to two keys so each test states every key it uses.
TWO_KEYS = [("AC01", 0), ("AC02", 1)]


class ModifierMapTests(unittest.TestCase):
    def test_ergopti_levels_follow_its_modifier_map(self):
        layout = keylayout_to_xkb.parse_keylayout(registry_keylayout("ergopti"))
        indices = [layout.key_map_index(mods) for mods in keylayout_to_xkb.XKB_LEVELS]
        self.assertEqual(indices, [0, 1, 2, 3, 4, 5, 6])

    def test_ergol_levels_follow_its_modifier_map(self):
        layout = keylayout_to_xkb.parse_keylayout(registry_keylayout("ergol"))
        indices = [layout.key_map_index(mods) for mods in keylayout_to_xkb.XKB_LEVELS]
        # caps alone has its own map; shift ignores caps; command falls back
        # to the default index.
        self.assertEqual(indices, [0, 2, 1, 1, 0, 3, 4])

    def test_an_unlisted_pressed_modifier_does_not_match(self):
        layout = keylayout_to_xkb.parse_keylayout(synthetic('<keyMap index="0"/>'))
        self.assertEqual(layout.key_map_index(frozenset({"shift", "caps"})), 1, "caps? is optional")
        self.assertEqual(
            layout.key_map_index(frozenset({"shift", "option"})), 0, "shift+option is unlisted"
        )

    def test_an_unknown_modifier_token_is_rejected(self):
        broken = synthetic(
            '<keyMap index="0"/>',
            modifier_map='<modifierMap id="m" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys="hyper"/></keyMapSelect></modifierMap>',
        )
        with self.assertRaises(keylayout_to_xkb.KeylayoutError):
            keylayout_to_xkb.parse_keylayout(broken)


class ParsingTests(unittest.TestCase):
    def test_entities_and_control_characters(self):
        layout = keylayout_to_xkb.parse_keylayout(
            synthetic(
                '<keyMap index="0"><key code="0" output="&#x0022;"/><key code="1" output="&#x0010;"/></keyMap>'
            )
        )
        self.assertEqual(keylayout_to_xkb.resolve(layout, 0, 0).text, '"')
        self.assertEqual(
            keylayout_to_xkb.resolve(layout, 0, 1).kind, "none", "a control output types nothing"
        )

    def test_base_map_set_fills_missing_keys(self):
        layout = keylayout_to_xkb.parse_keylayout(
            synthetic(
                '<keyMap index="0"><key code="0" output="a"/><key code="1" output="s"/></keyMap>'
                '<keyMap index="1" baseMapSet="s" baseIndex="0"><key code="0" output="A"/></keyMap>'
            )
        )
        self.assertEqual(keylayout_to_xkb.resolve(layout, 1, 0).text, "A")
        self.assertEqual(
            keylayout_to_xkb.resolve(layout, 1, 1).text, "s", "inherited from keyMap 0"
        )

    def test_comments_hiding_tags_are_ignored(self):
        layout = keylayout_to_xkb.parse_keylayout(
            synthetic(
                '<!-- <key code="0" output="x"/> --><keyMap index="0"><key code="0" output="a"/></keyMap>'
            )
        )
        self.assertEqual(keylayout_to_xkb.resolve(layout, 0, 0).text, "a")

    def test_a_layout_without_default_layout_element_is_rejected(self):
        text = synthetic('<keyMap index="0"/>').replace('first="0"', 'first="18"')
        with self.assertRaises(keylayout_to_xkb.KeylayoutError):
            keylayout_to_xkb.parse_keylayout(text)

    def test_an_undefined_action_is_rejected(self):
        text = synthetic('<keyMap index="0"><key code="0" action="ghost"/></keyMap>')
        layout = keylayout_to_xkb.parse_keylayout(text)
        with self.assertRaises(keylayout_to_xkb.KeylayoutError):
            keylayout_to_xkb.resolve(layout, 0, 0)


class DeadKeyConversionTests(unittest.TestCase):
    def convert(self, text):
        return keylayout_to_xkb.convert(text, TWO_KEYS, "synthetic", "Synthetic")

    def test_a_chained_dead_key_gets_a_two_key_sequence(self):
        text = synthetic(
            '<keyMap index="0"><key code="0" action="acute"/><key code="1" action="e"/></keyMap>',
            actions=(
                '<action id="acute"><when state="none" next="acute"/><when state="acute" next="doubleacute"/></action>'
                '<action id="e"><when state="none" output="e"/><when state="acute" output="é"/>'
                '<when state="doubleacute" output="ő"/></action>'
            ),
            terminators='<when state="acute" output="´"/><when state="doubleacute" output="˝"/>',
        )
        result = self.convert(text)
        self.assertEqual(
            result.key_symbols["AC01"][0], "dead_acute", "named after a standard dead keysym"
        )
        self.assertIn('<dead_acute> <e>\t: "é"', result.compose_text)
        self.assertIn('<dead_acute> <dead_acute> <e>\t: "ő"', result.compose_text)

    def test_a_dead_key_without_keysym_borrows_one_nobody_types(self):
        text = synthetic(
            '<keyMap index="0"><key code="0" action="x"/><key code="1" output="⅝"/></keyMap>',
            actions='<action id="x"><when state="none" next="custom"/><when state="custom" output="y"/></action>',
            terminators='<when state="custom" output="ꟹ"/>',
        )
        result = self.convert(text)
        trigger = result.dead_triggers["custom"]
        self.assertNotEqual(trigger, "fiveeighths", "the layout types ⅝ itself")
        self.assertEqual(result.key_symbols["AC01"][0], trigger)

    def test_two_keys_typing_one_keysym_in_a_dead_state_are_reported(self):
        text = synthetic(
            '<keyMap index="0"><key code="0" action="d"/><key code="1" action="a1"/></keyMap>'
            '<keyMap index="1"><key code="0" action="d"/><key code="1" action="a2"/></keyMap>',
            actions=(
                '<action id="d"><when state="none" next="grave"/></action>'
                '<action id="a1"><when state="none" output="a"/><when state="grave" output="à"/></action>'
                '<action id="a2"><when state="none" output="a"/><when state="grave" output="ǎ"/></action>'
            ),
            terminators='<when state="grave" output="`"/>',
        )
        result = self.convert(text)
        self.assertEqual(result.conflicts, [("<dead_grave> <a>", "à", "ǎ")])
        self.assertEqual(result.compose_text.count("<dead_grave> <a>"), 1)

    def test_multi_character_outputs_go_through_compose(self):
        text = synthetic(
            '<keyMap index="0"><key code="0" output="où"/><key code="1" output="s"/></keyMap>'
        )
        result = self.convert(text)
        keysym = result.key_symbols["AC01"][0]
        self.assertIn(keysym, keylayout_to_xkb.BORROWED_KEYSYMS)
        self.assertIn('<%s> : "où"' % keysym, result.compose_text)


class KeycodeTableTests(unittest.TestCase):
    def test_both_conventions_cover_49_distinct_keys(self):
        table = json.loads(KEYCODES_PATH.read_text(encoding="utf-8"))
        self.assertEqual(len({key["xkb"] for key in table["keys"]}), 49)
        self.assertEqual(len({key["ahk"] for key in table["keys"]}), 49)
        self.assertEqual(len({key["code"] for key in table["keys"]}), 49)
        iso = dict(keylayout_to_xkb.load_keycodes(KEYCODES_PATH, "iso"))
        ansi = dict(keylayout_to_xkb.load_keycodes(KEYCODES_PATH, "ansi"))
        self.assertEqual(len(set(iso.values())), 49)
        self.assertEqual(len(set(ansi.values())), 49)
        swapped = sorted(name for name in iso if iso[name] != ansi[name])
        self.assertEqual(swapped, ["LSGT", "TLDE"], "only the two ISO/ANSI keys differ")
        self.assertEqual((iso["TLDE"], iso["LSGT"]), (10, 50))

    def test_an_unknown_convention_is_rejected(self):
        with self.assertRaises(keylayout_to_xkb.KeylayoutError):
            keylayout_to_xkb.load_keycodes(KEYCODES_PATH, "jis")


class CommandLineTests(unittest.TestCase):
    def test_the_cli_writes_a_complete_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            keylayout = Path(tmp) / "ergol.keylayout"
            keylayout.write_text(registry_keylayout("ergol"), encoding="utf-8")
            out = Path(tmp) / "out"
            with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()):
                code = keylayout_to_xkb.main(
                    [
                        "--keylayout",
                        str(keylayout),
                        "--keycodes",
                        str(KEYCODES_PATH),
                        "--convention",
                        "ansi",
                        "--layout-id",
                        "ergol",
                        "--display-name",
                        "Ergo-L 1.0.2",
                        "--index",
                        str(INDEX_PATH),
                        "--out",
                        str(out),
                    ]
                )
            self.assertEqual(code, 0)
            for name in ("ergol.xkb", "ergol.XCompose", "xkb_types.txt"):
                self.assertTrue((out / name).is_file(), name)
                self.assertNotIn(b"\r", (out / name).read_bytes(), name)

    def test_the_cli_fails_with_a_message_on_a_broken_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            keylayout = Path(tmp) / "broken.keylayout"
            keylayout.write_text("<keyboard/>", encoding="utf-8")
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                code = keylayout_to_xkb.main(
                    [
                        "--keylayout",
                        str(keylayout),
                        "--keycodes",
                        str(KEYCODES_PATH),
                        "--convention",
                        "iso",
                        "--layout-id",
                        "broken",
                        "--display-name",
                        "Broken",
                        "--out",
                        str(Path(tmp) / "out"),
                    ]
                )
            self.assertEqual(code, 3)
            self.assertIn("keylayout_to_xkb:", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
