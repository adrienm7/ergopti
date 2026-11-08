"""No written Compose sequence is shadowed by the locale table it includes.

Every generated XCompose starts with ``include "%L"``. Compose keeps an
inherited sequence and skips a shorter rule written after it, so a written
terminal that the locale extends never completes: Bépo's monnaie dead key then
its cedilla dead key waited for the locale's ``<dead_currency> <dead_cedilla>
<c>`` (₵) instead of typing ₢ (DKS-001). The converter gives the dead key
starting such a sequence a borrowed trigger. The native test feeds the real
libxkbcommon Compose state machine with the installed locale when the host has
both; the structural tests run everywhere.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import re
import unittest
from pathlib import Path

from support import convert_registry_layout, keylayout_to_xkb, registry_entries

_LINE_RE = re.compile(r'^((?:<[^>]+>\s*)+):\s*"((?:[^"\\]|\\.)*)"\s*$')
_LOCALE_COMPOSE = Path("/usr/share/X11/locale/en_US.UTF-8/Compose")
_COMPOSE_COMPOSED = 2


def written_sequences(compose_text: str) -> dict:
    """Sequence (tuple of keysyms) -> unescaped output of every written line."""
    found = {}
    for line in compose_text.splitlines():
        match = _LINE_RE.match(line)
        if match:
            keys = tuple(re.findall(r"<([^>]+)>", match.group(1)))
            found[keys] = re.sub(r"\\(.)", r"\1", match.group(2))
    return found


def terminals(sequences: dict) -> set:
    """Written sequences that no other written sequence extends."""
    prefixes = {keys[:size] for keys in sequences for size in range(1, len(keys))}
    return {keys for keys in sequences if keys not in prefixes}


class LocaleShadowingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.extended = keylayout_to_xkb.load_locale_extended_prefixes()
        cls.bepo = convert_registry_layout("bepo")
        cls.bepo_sequences = written_sequences(cls.bepo.compose_text)

    def test_no_registry_terminal_is_a_sequence_the_locale_extends_dks_001(self):
        shadowed = []
        for entry in registry_entries():
            sequences = written_sequences(convert_registry_layout(entry["id"]).compose_text)
            for keys in terminals(sequences):
                if keys in self.extended:
                    shadowed.append("%s: %s" % (entry["id"], " ".join(keys)))
        self.assertEqual(shadowed, [])

    def test_bepo_monnaie_then_cedilla_types_the_cruzeiro_sign_dks_001(self):
        monnaie = self.bepo.dead_triggers["monnaie"]
        cedilla = self.bepo.dead_triggers["cedille"]
        self.assertNotIn(monnaie, keylayout_to_xkb.KNOWN_DEAD_KEYSYMS)
        self.assertEqual(cedilla, "dead_cedilla", "only the shadowed head moves")
        self.assertEqual(self.bepo_sequences[(monnaie, cedilla)], "₢")
        # The rest of the monnaie state is still written under its new trigger.
        self.assertEqual(self.bepo_sequences[(monnaie, "c")], "¢")
        self.assertEqual(self.bepo_sequences[(monnaie,)], "¤")

    def test_unshadowed_dead_keys_keep_their_standard_keysym(self):
        self.assertEqual(self.bepo.dead_triggers["cedille"], "dead_cedilla")
        self.assertEqual(self.bepo.dead_triggers["breve"], "dead_breve")

    def test_the_pinned_prefixes_hold_the_cedi_sign_path(self):
        self.assertIn(("dead_currency", "dead_cedilla"), self.extended)
        self.assertTrue(all(len(keys) >= 2 for keys in self.extended))


def _load_libxkbcommon():
    name = ctypes.util.find_library("xkbcommon")
    if name is None:
        return None
    lib = ctypes.CDLL(name)
    signatures = [
        ("xkb_context_new", ctypes.c_void_p, [ctypes.c_int]),
        (
            "xkb_compose_table_new_from_buffer",
            ctypes.c_void_p,
            [
                ctypes.c_void_p,
                ctypes.c_char_p,
                ctypes.c_size_t,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_int,
            ],
        ),
        ("xkb_compose_state_new", ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_int]),
        ("xkb_keysym_from_name", ctypes.c_uint32, [ctypes.c_char_p, ctypes.c_int]),
        ("xkb_compose_state_feed", ctypes.c_int, [ctypes.c_void_p, ctypes.c_uint32]),
        ("xkb_compose_state_reset", None, [ctypes.c_void_p]),
        ("xkb_compose_state_get_status", ctypes.c_int, [ctypes.c_void_p]),
        (
            "xkb_compose_state_get_utf8",
            ctypes.c_int,
            [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t],
        ),
    ]
    for function, restype, argtypes in signatures:
        getattr(lib, function).restype = restype
        getattr(lib, function).argtypes = argtypes
    return lib


_LIB = _load_libxkbcommon()


@unittest.skipUnless(
    _LIB is not None and _LOCALE_COMPOSE.is_file(),
    "needs libxkbcommon and the libX11 en_US.UTF-8 Compose table",
)
class NativeComposeTests(unittest.TestCase):
    """The generated table on the real Compose state machine, locale included."""

    def compose(self, table_text: str, keysyms) -> tuple:
        context = _LIB.xkb_context_new(0)
        data = table_text.encode("utf-8")
        table = _LIB.xkb_compose_table_new_from_buffer(
            context, data, len(data), b"en_US.UTF-8", 1, 0
        )
        self.assertIsNotNone(table, "libxkbcommon parses the table")
        state = _LIB.xkb_compose_state_new(table, 0)
        for name in keysyms:
            keysym = _LIB.xkb_keysym_from_name(name.encode("ascii"), 0)
            self.assertNotEqual(keysym, 0, name)
            _LIB.xkb_compose_state_feed(state, keysym)
        buffer = ctypes.create_string_buffer(64)
        _LIB.xkb_compose_state_get_utf8(state, buffer, 64)
        return _LIB.xkb_compose_state_get_status(state), buffer.value.decode("utf-8")

    def test_bepo_monnaie_then_cedilla_composes_at_the_second_key_dks_001(self):
        bepo = convert_registry_layout("bepo")
        pair = [bepo.dead_triggers["monnaie"], bepo.dead_triggers["cedille"]]
        self.assertEqual(self.compose(bepo.compose_text, pair), (_COMPOSE_COMPOSED, "₢"))

    def test_the_standard_trigger_is_what_the_locale_shadowed(self):
        """Control: the old rule under the locale never completes at the pair."""
        table = 'include "%L"\n\n<dead_currency> <dead_cedilla>\t: "₢"\n'
        status, _text = self.compose(table, ["dead_currency", "dead_cedilla"])
        self.assertNotEqual(status, _COMPOSE_COMPOSED)
        table = '<dead_currency> <dead_cedilla>\t: "₢"\n'
        self.assertEqual(
            self.compose(table, ["dead_currency", "dead_cedilla"]), (_COMPOSE_COMPOSED, "₢")
        )

    def test_locale_compositions_still_apply_to_other_dead_keys(self):
        bepo = convert_registry_layout("bepo")
        self.assertEqual(
            self.compose(bepo.compose_text, ["Multi_key", "o", "c"]), (_COMPOSE_COMPOSED, "©")
        )

    def test_every_bepo_terminal_completes_natively(self):
        bepo = convert_registry_layout("bepo")
        sequences = written_sequences(bepo.compose_text)
        context = _LIB.xkb_context_new(0)
        data = bepo.compose_text.encode("utf-8")
        table = _LIB.xkb_compose_table_new_from_buffer(
            context, data, len(data), b"en_US.UTF-8", 1, 0
        )
        state = _LIB.xkb_compose_state_new(table, 0)
        stuck = []
        for keys in sorted(terminals(sequences)):
            _LIB.xkb_compose_state_reset(state)
            for name in keys:
                _LIB.xkb_compose_state_feed(state, _LIB.xkb_keysym_from_name(name.encode(), 0))
            if _LIB.xkb_compose_state_get_status(state) != _COMPOSE_COMPOSED:
                stuck.append(" ".join(keys))
        self.assertEqual(stuck, [])


if __name__ == "__main__":
    unittest.main()
