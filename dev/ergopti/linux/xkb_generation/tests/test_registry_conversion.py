"""Every registry layout converts, and Ergo-L converts completely.

The completeness oracle reads the .keylayout with its own regular expressions
and a level map derived by hand from Ergo-L's modifierMap, so a converter bug
cannot bless itself through a shared helper:

- every key of the alphanumeric block types, at each of the seven levels, the
  character the .keylayout gives it (or its Compose stand-in), and a key that
  types nothing gets NoSymbol;
- every dead key, chained ones included, gets a trigger no other key types,
  and every character a key types inside a reachable dead-key state has its
  Compose sequence;
- the only printable keys left out are the keypad's, which XKB keeps.
"""

from __future__ import annotations

import html
import json
import re
import unittest

from support import (
    KEYCODES_PATH,
    convert_registry_layout,
    keylayout_to_xkb,
    registry_entries,
    registry_keylayout,
)

# keyMap index per XKB level for Ergo-L, read off its modifierMap by hand:
# base, caps -> "caps" (2), shift and caps+shift -> "anyShift caps?" (1),
# command -> no select, default index 0, option -> 3, shift+option -> 4.
ERGOL_LEVEL_INDICES = [0, 2, 1, 1, 0, 3, 4]
KEYPAD_CODES = range(65, 93)

# (dead-key state, action) outputs the shipped Ergopti XCompose files cannot
# reach: the action's key is itself a dead key, so it sends its dead keysym, not
# the character its Compose line names. The golden test freezes those files
# (docs/memory/linux-web-release.md); any other layout must have none, so a new
# registry layout that hits this converter limit fails here instead of shipping
# sequences nobody can type.
ERGOPTI_FAMILY = {"ergopti", "ergopti_ansi", "ergopti_plus", "ergopti_plus_ansi"}
ERGOPTI_UNREACHABLE = {("s1_circumflex", "^"), ("s1_circumflex", "¨"), ("s3_diaeresis", "¨")}

_COMPOSE_LINE_RE = re.compile(r'^((?:<[^>]+>\s*)+):\s*"((?:[^"\\]|\\.)*)"\s*$')


def _unescape_compose(text: str) -> str:
    return re.sub(r"\\(.)", r"\1", text)


def parse_compose(text: str) -> dict:
    """Sequence (tuple of keysyms) -> output of every Compose line."""
    sequences = {}
    for line in text.splitlines():
        match = _COMPOSE_LINE_RE.match(line)
        if match:
            keys = tuple(re.findall(r"<([^>]+)>", match.group(1)))
            sequences[keys] = _unescape_compose(match.group(2))
    return sequences


class KeylayoutOracle:
    """Direct regex reading of a .keylayout, independent of the converter."""

    def __init__(self, text: str):
        body = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
        self.key_maps = {}
        for index, inner in re.findall(
            r'<keyMap index="(\d+)"[^>]*>(.*?)</keyMap>', body, re.DOTALL
        ):
            keys = {}
            for code, kind, value in re.findall(
                r'<key code="(\d+)"\s+(output|action)="([^"]*)"', inner
            ):
                keys.setdefault(int(code), (kind, html.unescape(value)))
            self.key_maps[int(index)] = keys
        self.actions = {}
        for action_id, inner in re.findall(
            r'<action id="([^"]*)"\s*>(.*?)</action>', body, re.DOTALL
        ):
            whens = {}
            for attrs in re.findall(r"<when\s+([^>]*?)/?>", inner):
                fields = dict(re.findall(r'(\w+)="([^"]*)"', attrs))
                whens[fields["state"]] = (
                    html.unescape(fields.get("output", "")),
                    fields.get("next"),
                )
            self.actions[html.unescape(action_id)] = whens
        terminators = re.search(r"<terminators>(.*?)</terminators>", body, re.DOTALL).group(1)
        self.terminators = {
            state: html.unescape(output)
            for state, output in re.findall(
                r'<when\s+state="([^"]*)"\s+output="([^"]*)"', terminators
            )
        }

    def cell(self, index: int, code: int):
        """("text", output) | ("dead", state) | ("none", "") and the action id."""
        entry = self.key_maps[index].get(code)
        if entry is None:
            return ("none", ""), ""
        kind, value = entry
        if kind == "output":
            return (("text", value) if printable(value) else ("none", "")), ""
        output, next_state = self.actions[value]["none"]
        if next_state:
            return ("dead", next_state), value
        return (("text", output) if printable(output) else ("none", "")), value


def printable(text: str) -> bool:
    return bool(text) and all(not (ord(c) < 0x20 or 0x7F <= ord(c) <= 0x9F) for c in text)


def keysym_to_text(keysym: str, names: dict) -> str:
    unicode_match = re.fullmatch(r"U([0-9A-F]{4,6})", keysym)
    if unicode_match:
        return chr(int(unicode_match.group(1), 16))
    return names.get(keysym, "")


class RegistryConversionTests(unittest.TestCase):
    def test_every_registry_layout_converts(self):
        entries = registry_entries()
        self.assertGreaterEqual(len(entries), 5)
        for entry in entries:
            result = convert_registry_layout(entry["id"])
            self.assertEqual(len(result.key_symbols), 49, entry["id"])
            self.assertIn('xkb_symbols "%s"' % entry["id"], result.symbols_text)
            self.assertTrue(result.compose_text.startswith('include "%L"'), entry["id"])
            self.assertEqual(result.conflicts, [], entry["id"])

    def test_every_dead_key_output_is_reachable_from_its_own_key(self):
        entries = registry_entries()
        self.assertGreaterEqual(len(entries), 5)
        self.assertTrue(ERGOPTI_FAMILY <= {entry["id"] for entry in entries})
        for entry in entries:
            result = convert_registry_layout(entry["id"])
            expected = ERGOPTI_UNREACHABLE if entry["id"] in ERGOPTI_FAMILY else set()
            self.assertEqual(set(result.unreachable), expected, entry["id"])


class ErgolCompletenessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.entry = next(entry for entry in registry_entries() if entry["id"] == "ergol")
        cls.oracle = KeylayoutOracle(registry_keylayout("ergol"))
        cls.result = convert_registry_layout("ergol")
        cls.compose = parse_compose(cls.result.compose_text)
        table = json.loads(KEYCODES_PATH.read_text(encoding="utf-8"))
        cls.keys = [
            (key["xkb"], key["mac"]["ansi"] if isinstance(key["mac"], dict) else key["mac"])
            for key in table["keys"]
        ]
        symbols = json.loads(
            (keylayout_to_xkb.DATA_DIR / "key_sym.json").read_text(encoding="utf-8")
        )
        cls.keysym_names = {
            name: char for char, name in symbols["keysyms"].items() if len(char) == 1
        }

    def cells(self):
        for xkb, code in self.keys:
            for level, index in enumerate(ERGOL_LEVEL_INDICES):
                cell, action = self.oracle.cell(index, code)
                yield xkb, code, level, cell, action, self.result.key_symbols[xkb][level]

    def test_ergol_uses_the_ansi_numbering(self):
        self.assertEqual(self.entry["keycode_convention"], "ansi")
        tlde = self.result.key_symbols["TLDE"]
        self.assertEqual(tlde[0], "grave", "Ergo-L types ` on the key left of 1")
        self.assertEqual(self.result.key_symbols["LSGT"][0], "less")

    def test_every_key_and_level_types_what_the_keylayout_says(self):
        checked = 0
        problems = []
        for xkb, _code, level, (kind, value), _action, keysym in self.cells():
            checked += 1
            if kind == "none":
                ok = keysym == keylayout_to_xkb.NO_SYMBOL
            elif kind == "dead":
                ok = keysym == self.result.dead_triggers.get(value)
            elif len(value) == 1:
                ok = keysym_to_text(keysym, self.keysym_names) == value
            else:
                ok = self.compose.get((keysym,)) == value
            if not ok:
                problems.append("%s level %d: %s %r -> %s" % (xkb, level, kind, value, keysym))
        self.assertEqual(problems, [])
        self.assertEqual(checked, 49 * 7)

    def test_dead_key_triggers_are_unique_to_dead_keys(self):
        triggers = set(self.result.dead_triggers.values())
        self.assertGreaterEqual(
            len(triggers), 15, "Ergo-L has at least 15 dead keys on the main block"
        )
        self.assertEqual(
            len(triggers), len(self.result.dead_triggers), "two dead keys share a trigger"
        )
        typed = {keysym for *_rest, (kind, _v), _a, keysym in self.cells() if kind == "text"}
        self.assertEqual(triggers & typed, set(), "a plain key types a dead-key trigger")

    def reachable_prefixes(self):
        """Keysym prefixes entering each dead state, from the oracle's view."""
        prefixes = {}
        for _xkb, _code, _level, (kind, state), _action, keysym in self.cells():
            if kind == "dead":
                prefixes.setdefault(state, set()).add((keysym,))
        changed = True
        while changed:
            changed = False
            for _xkb, _code, _level, _cell, action, keysym in self.cells():
                if not action:
                    continue
                for state, (_output, next_state) in self.oracle.actions[action].items():
                    if state == "none" or not next_state or state not in prefixes:
                        continue
                    for prefix in list(prefixes[state]):
                        candidate = prefix + (keysym,)
                        if candidate not in prefixes.setdefault(next_state, set()):
                            prefixes[next_state].add(candidate)
                            changed = True
        return prefixes

    def test_every_dead_key_sequence_is_composed(self):
        prefixes = self.reachable_prefixes()
        self.assertIn("greek", prefixes, "the chained 1dk + g dead key was not found")
        self.assertIn("diaeresis", prefixes)
        self.assertTrue(any(len(prefix) == 2 for prefix in prefixes["greek"]))
        checked = 0
        missing = []
        for _xkb, _code, _level, _cell, action, keysym in self.cells():
            if not action:
                continue
            for state, (output, _next) in self.oracle.actions[action].items():
                if state == "none" or not output or state not in prefixes:
                    continue
                for prefix in prefixes[state]:
                    checked += 1
                    sequence = prefix + (keysym,)
                    if self.compose.get(sequence) != output:
                        missing.append(
                            "%s -> %r (got %r)"
                            % (" ".join(sequence), output, self.compose.get(sequence))
                        )
        self.assertEqual(missing, [])
        self.assertGreater(checked, 500)

    def test_only_the_keypad_is_left_to_the_system(self):
        mapped = {code for _xkb, code in self.keys}
        left_out = set()
        for keys in self.oracle.key_maps.values():
            for code, (kind, value) in keys.items():
                if kind == "output" and not printable(value):
                    continue
                if code not in mapped and code not in KEYPAD_CODES:
                    left_out.add(code)
        self.assertEqual(left_out, set())

    def test_the_conversion_has_no_compose_conflict(self):
        self.assertEqual(self.result.conflicts, [])


if __name__ == "__main__":
    unittest.main()
