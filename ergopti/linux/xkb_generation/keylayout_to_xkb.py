"""Convert any macOS .keylayout into an XKB symbols file and an XCompose file.

This is the one converter from the layout registry's only layout format (a
macOS keyboard layout) to Linux. The repository uses it to regenerate the
shipped Ergopti files (generate_xkb_files.py), and the Linux package runs it on
the user's machine when a registry layout is installed, so it must stay
standard-library only and importable by the oldest Python the installers
support (3.8).

Nothing here is specific to one layout:

- the characters of each XKB level are read from the keyMap that the layout's
  own modifierMap selects for that modifier combination;
- physical keys come from the shared macOS keycode table, read through the
  layout's keycode convention (Apple ISO or ANSI numbering of two keys);
- dead keys come from the layout's actions and terminators, chained dead keys
  included; their XKB trigger is the standard dead keysym when one exists;
- outputs longer than one character go through XCompose.

Per-layout XKB choices that cannot be derived come from the registry index
entry's ``xkb`` table (see XkbHints): the Ergopti files map a few outputs to
fixed keysyms, and type its magic key only on the base level.

An action named with a single character stands for that character (the
convention of the tools that produced the Ergopti layouts); longer action ids
(Kalamine's "ad01_q") stand for what the action types.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

DATA_DIR = Path(__file__).resolve().parent / "data"

# Key type every generated key uses; defined by data/xkb_types.txt.
TYPE_NAME = "ERGOPTI_SEVEN_LEVEL"

# The seven levels of that type, each described by the macOS modifiers that
# produce the same characters. The order is the order of the XKB levels.
XKB_LEVELS: Tuple[frozenset, ...] = (
    frozenset(),
    frozenset({"caps"}),
    frozenset({"shift"}),
    frozenset({"shift", "caps"}),
    frozenset({"command"}),
    frozenset({"option"}),
    frozenset({"shift", "option"}),
)

# modifierMap tokens (Apple TN2056), folded onto the five modifiers the
# conversion distinguishes. Left/right variants are not told apart.
MODIFIER_TOKENS = {
    "shift": "shift",
    "rightShift": "shift",
    "anyShift": "shift",
    "option": "option",
    "rightOption": "option",
    "anyOption": "option",
    "control": "control",
    "rightControl": "control",
    "anyControl": "control",
    "command": "command",
    "caps": "caps",
}

# XKB dead keysyms, used as the trigger of a dead key whose state is named
# after one of them (Kalamine names its states "acute", "greek", ...).
KNOWN_DEAD_KEYSYMS = frozenset(
    {
        "dead_grave",
        "dead_acute",
        "dead_circumflex",
        "dead_tilde",
        "dead_perispomeni",
        "dead_macron",
        "dead_breve",
        "dead_abovedot",
        "dead_diaeresis",
        "dead_abovering",
        "dead_doubleacute",
        "dead_caron",
        "dead_cedilla",
        "dead_ogonek",
        "dead_iota",
        "dead_belowdot",
        "dead_hook",
        "dead_horn",
        "dead_stroke",
        "dead_abovecomma",
        "dead_abovereversedcomma",
        "dead_doublegrave",
        "dead_belowring",
        "dead_belowmacron",
        "dead_belowcircumflex",
        "dead_belowtilde",
        "dead_belowbreve",
        "dead_belowdiaeresis",
        "dead_invertedbreve",
        "dead_belowcomma",
        "dead_currency",
        "dead_lowline",
        "dead_aboveverticalline",
        "dead_belowverticalline",
        "dead_longsolidusoverlay",
        "dead_greek",
        "dead_hamza",
    }
)

# XKB dead keysyms by the character a dead key types on its own, for layouts
# whose state names say nothing (Ergopti's "s1_circumflex" types "^").
DEAD_KEYSYMS_BY_TERMINATOR = {
    "`": "dead_grave",
    "´": "dead_acute",
    "^": "dead_circumflex",
    "~": "dead_tilde",
    "¯": "dead_macron",
    "ˉ": "dead_macron",
    "˘": "dead_breve",
    "˙": "dead_abovedot",
    "¨": "dead_diaeresis",
    "˚": "dead_abovering",
    "˝": "dead_doubleacute",
    "ˇ": "dead_caron",
    "¸": "dead_cedilla",
    "˛": "dead_ogonek",
    "¤": "dead_currency",
    "µ": "dead_greek",
}

# Keysyms no layout is expected to type, borrowed to carry an output longer
# than one character or a dead key without a keysym of its own; XCompose
# turns each back into its text. Taken in sorted order; a keysym the layout
# already types is skipped.
BORROWED_KEYSYMS = (
    "fiveeighths",
    "fivesixths",
    "fourfifths",
    "oneeighth",
    "onefifth",
    "onesixth",
    "onethird",
    "seveneighths",
    "threeeighths",
    "threefifths",
    "twofifths",
    "twothirds",
)
# Once those are used up, Unicode private-use keysyms take over: they are
# never on a keyboard and render nothing recognisable if Compose is off.
PRIVATE_USE_FIRST = 0xF0000

NO_SYMBOL = "NoSymbol"


class KeylayoutError(ValueError):
    """The .keylayout is malformed or uses a construct the converter rejects."""


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
_TAG_RE = re.compile(
    r"<(/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[A-Za-z_:][\w:.-]*\s*=\s*\"[^\"]*\")*)\s*(/?)>"
)
_ATTR_RE = re.compile(r"([A-Za-z_:][\w:.-]*)\s*=\s*\"([^\"]*)\"")
_ENTITY_RE = re.compile(r"&(#x[0-9A-Fa-f]+|#[0-9]+|lt|gt|amp|quot|apos);")
_NAMED_ENTITIES = {"lt": "<", "gt": ">", "amp": "&", "quot": '"', "apos": "'"}


def decode_entities(value: str) -> str:
    """Decode the XML character references a .keylayout attribute can hold."""

    def replace(match: "re.Match[str]") -> str:
        token = match.group(1)
        if token.startswith("#x"):
            return chr(int(token[2:], 16))
        if token.startswith("#"):
            return chr(int(token[1:]))
        return _NAMED_ENTITIES[token]

    return _ENTITY_RE.sub(replace, value)


def is_printable(text: str) -> bool:
    """Whether ``text`` types something visible (no C0/C1 control character)."""
    if not text:
        return False
    return all(not (ord(char) < 0x20 or 0x7F <= ord(char) <= 0x9F) for char in text)


class Action:
    """One <action>: what it does in each dead-key state."""

    def __init__(self, action_id: str):
        self.id = action_id
        # state -> (output or None, next state or None), in document order.
        self.whens: Dict[str, Tuple[Optional[str], Optional[str]]] = {}


class Keylayout:
    """The parts of a .keylayout the converters read."""

    def __init__(self) -> None:
        self.name = ""
        self.map_set_id = ""
        self.default_index = 0
        # (keyMap index, [(required modifiers, optional modifiers), ...])
        self.selects: List[Tuple[int, List[Tuple[frozenset, frozenset]]]] = []
        # keyMapSet id -> index -> code -> ("output"|"action", value)
        self.key_map_sets: Dict[str, Dict[int, Dict[int, Tuple[str, str]]]] = {}
        # keyMapSet id -> index -> (base keyMapSet id, base index)
        self.key_map_bases: Dict[str, Dict[int, Tuple[str, int]]] = {}
        self.actions: Dict[str, Action] = {}
        self.terminators: Dict[str, str] = {}

    # -- modifiers ---------------------------------------------------------

    def key_map_index(self, pressed: frozenset) -> int:
        """keyMap index the layout selects when exactly ``pressed`` are down."""
        for index, modifiers in self.selects:
            for required, optional in modifiers:
                if required <= pressed and pressed <= (required | optional):
                    return index
        return self.default_index

    # -- keys --------------------------------------------------------------

    def key_entry(self, index: int, code: int) -> Optional[Tuple[str, str]]:
        """The <key> of ``code`` in keyMap ``index``, following baseMapSet."""
        return self._key_entry(self.map_set_id, index, code, 0)

    def _key_entry(
        self, map_set: str, index: int, code: int, depth: int
    ) -> Optional[Tuple[str, str]]:
        if depth > 8:
            raise KeylayoutError("keyMap base chain is too deep (cycle?)")
        maps = self.key_map_sets.get(map_set)
        if maps is None:
            raise KeylayoutError("keyMapSet %r is not defined" % map_set)
        entries = maps.get(index)
        if entries is not None and code in entries:
            return entries[code]
        base = self.key_map_bases.get(map_set, {}).get(index)
        if base is not None:
            return self._key_entry(base[0], base[1], code, depth + 1)
        return None


def _parse_modifier_keys(keys: str) -> Tuple[frozenset, frozenset]:
    required, optional = set(), set()
    for token in keys.split():
        is_optional = token.endswith("?")
        name = token[:-1] if is_optional else token
        if name not in MODIFIER_TOKENS:
            raise KeylayoutError("unknown modifier token %r" % token)
        (optional if is_optional else required).add(MODIFIER_TOKENS[name])
    return frozenset(required), frozenset(optional - required)


def parse_keylayout(text: str) -> Keylayout:
    """Parse the text of a .keylayout.

    Raises:
        KeylayoutError: when a part every conversion needs is missing.
    """
    layout = Keylayout()
    body = _COMMENT_RE.sub("", text)
    layouts: List[Dict[str, str]] = []
    modifier_maps: Dict[str, Tuple[int, List[Tuple[int, List[Tuple[frozenset, frozenset]]]]]] = {}
    current_modifier_map: Optional[str] = None
    current_select: Optional[Tuple[int, List[Tuple[frozenset, frozenset]]]] = None
    current_map_set: Optional[str] = None
    current_key_map: Optional[int] = None
    current_action: Optional[Action] = None
    in_terminators = False

    for match in _TAG_RE.finditer(body):
        closing, tag, raw_attrs, self_closing = match.groups()
        attrs = {name: decode_entities(value) for name, value in _ATTR_RE.findall(raw_attrs)}
        if closing:
            if tag == "modifierMap":
                current_modifier_map = None
            elif tag == "keyMapSelect":
                current_select = None
            elif tag == "keyMapSet":
                current_map_set = None
            elif tag == "keyMap":
                current_key_map = None
            elif tag == "action":
                current_action = None
            elif tag == "terminators":
                in_terminators = False
            continue
        if tag == "keyboard":
            layout.name = attrs.get("name", "")
        elif tag == "layout":
            layouts.append(attrs)
        elif tag == "modifierMap":
            current_modifier_map = attrs["id"]
            modifier_maps[current_modifier_map] = (int(attrs.get("defaultIndex", "0")), [])
        elif tag == "keyMapSelect" and current_modifier_map is not None:
            current_select = (int(attrs["mapIndex"]), [])
            modifier_maps[current_modifier_map][1].append(current_select)
        elif tag == "modifier" and current_select is not None:
            current_select[1].append(_parse_modifier_keys(attrs.get("keys", "")))
        elif tag == "keyMapSet":
            current_map_set = attrs["id"]
            layout.key_map_sets.setdefault(current_map_set, {})
        elif tag == "keyMap" and current_map_set is not None:
            current_key_map = int(attrs["index"])
            layout.key_map_sets[current_map_set].setdefault(current_key_map, {})
            if "baseIndex" in attrs:
                base_set = attrs.get("baseMapSet", current_map_set)
                layout.key_map_bases.setdefault(current_map_set, {})[current_key_map] = (
                    base_set,
                    int(attrs["baseIndex"]),
                )
            if self_closing:
                current_key_map = None
        elif tag == "key" and current_map_set is not None and current_key_map is not None:
            code = int(attrs["code"])
            entries = layout.key_map_sets[current_map_set][current_key_map]
            if code in entries:
                continue
            if "output" in attrs:
                entries[code] = ("output", attrs["output"])
            elif "action" in attrs:
                entries[code] = ("action", attrs["action"])
        elif tag == "action":
            current_action = Action(attrs["id"])
            if current_action.id not in layout.actions:
                layout.actions[current_action.id] = current_action
            if self_closing:
                current_action = None
        elif tag == "when" and current_action is not None:
            state = attrs.get("state", "none")
            if state not in current_action.whens:
                output = attrs.get("output")
                current_action.whens[state] = (output if output else None, attrs.get("next"))
        elif tag == "when" and in_terminators:
            if "state" in attrs and attrs["state"] not in layout.terminators:
                layout.terminators[attrs["state"]] = attrs.get("output", "")
        elif tag == "terminators":
            in_terminators = True

    default_layout = next((item for item in layouts if item.get("first") == "0"), None)
    if default_layout is None:
        raise KeylayoutError('no <layout first="0"> element')
    layout.map_set_id = default_layout.get("mapSet", "")
    modifiers_id = default_layout.get("modifiers", "")
    if layout.map_set_id not in layout.key_map_sets:
        raise KeylayoutError("keyMapSet %r is not defined" % layout.map_set_id)
    if modifiers_id not in modifier_maps:
        raise KeylayoutError("modifierMap %r is not defined" % modifiers_id)
    layout.default_index, layout.selects = modifier_maps[modifiers_id]
    return layout


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------


class Resolved:
    """What one key types at one level, before choosing XKB keysyms.

    kind is "none", "text" (``text`` is the output) or "dead" (``state`` is the
    dead-key state it enters, ``text`` what that dead key types on its own).
    ``action`` is the id of the action the key uses, "" for a plain output.
    """

    __slots__ = ("kind", "text", "state", "action")

    def __init__(self, kind: str, text: str = "", state: str = "", action: str = ""):
        self.kind = kind
        self.text = text
        self.state = state
        self.action = action


class XkbHints:
    """Per-layout XKB choices, from the registry index entry's ``xkb`` table.

    keysym_overrides: ordered (output text, keysym) pairs used instead of the
        derived keysym; the order is the order XCompose lists them in.
    base_level_only: outputs the key types on the base level only; on the
        other levels it types the character its action is named after.
    """

    def __init__(
        self,
        keysym_overrides: Sequence[Tuple[str, str]] = (),
        base_level_only: Sequence[str] = (),
    ) -> None:
        self.keysym_overrides = [(text, keysym) for text, keysym in keysym_overrides]
        self.base_level_only = list(base_level_only)

    @classmethod
    def from_entry(cls, entry: dict) -> "XkbHints":
        xkb = entry.get("xkb", {})
        return cls(xkb.get("keysym_overrides", []), xkb.get("base_level_only", []))


def resolve(layout: Keylayout, index: int, code: int) -> Resolved:
    """What ``code`` types in keyMap ``index`` from the neutral state."""
    entry = layout.key_entry(index, code)
    if entry is None:
        return Resolved("none")
    kind, value = entry
    if kind == "output":
        return Resolved("text", value) if is_printable(value) else Resolved("none")
    action = layout.actions.get(value)
    if action is None:
        raise KeylayoutError("key %d uses undefined action %r" % (code, value))
    output, next_state = action.whens.get("none", (None, None))
    if next_state:
        return Resolved(
            "dead", layout.terminators.get(next_state, "") or action.id, next_state, action.id
        )
    if output and is_printable(output):
        return Resolved("text", output, action=action.id)
    return Resolved("none")


def load_keycodes(path: Path, convention: str) -> List[Tuple[str, int]]:
    """(XKB key name, macOS code) pairs from the shared keycode table."""
    table = json.loads(Path(path).read_text(encoding="utf-8"))
    if convention not in table["conventions"]:
        raise KeylayoutError("unknown keycode convention %r" % convention)
    pairs = []
    for key in table["keys"]:
        mac = key["mac"]
        pairs.append((key["xkb"], mac[convention] if isinstance(mac, dict) else mac))
    return pairs


def load_keysym_table() -> Dict[str, str]:
    return json.loads((DATA_DIR / "key_sym.json").read_text(encoding="utf-8"))["keysyms"]


def unicode_keysym(char: str) -> str:
    return "U%04X" % ord(char)


# ---------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------


class Conversion:
    """The result of converting one layout: files plus what they map."""

    def __init__(self) -> None:
        self.symbols_text = ""
        self.compose_text = ""
        # XKB key name -> the seven keysyms written for it.
        self.key_symbols: Dict[str, List[str]] = {}
        # Output text -> keysym standing for it (XCompose turns it back).
        self.borrowed: Dict[str, str] = {}
        # Dead-key state -> trigger keysym.
        self.dead_triggers: Dict[str, str] = {}
        # Dead-key state -> keysym sequences that enter it.
        self.dead_sequences: Dict[str, List[List[str]]] = {}
        # Compose sequences two actions map to different outputs. Compose
        # works on keysyms, so two keys typing the same keysym cannot be told
        # apart; the first output wins and the conflict is reported here.
        self.conflicts: List[Tuple[str, str, str]] = []
        # (dead-key state, action) outputs no key can reach: the Compose line
        # names the character the action is called after, but every key using
        # that action sends another keysym (a dead key pressed inside a
        # dead-key state sends its own dead keysym). Reported, not fixed, so
        # the shipped Ergopti files keep their historical sequences.
        self.unreachable: List[Tuple[str, str]] = []


class _Converter:
    def __init__(
        self,
        layout: Keylayout,
        keycodes: Sequence[Tuple[str, int]],
        hints: XkbHints,
    ) -> None:
        self.layout = layout
        self.keycodes = list(keycodes)
        self.keysyms = load_keysym_table()
        self.overrides = list(hints.keysym_overrides)
        self.level_indices = [layout.key_map_index(mods) for mods in XKB_LEVELS]
        self.result = Conversion()
        # Insertion order matters: XCompose lists these in this order.
        self.borrowed: Dict[str, str] = dict(self.overrides)
        self.grid: Dict[str, List[Resolved]] = {
            xkb: [resolve(layout, index, code) for index in self.level_indices]
            for xkb, code in self.keycodes
        }
        for cells in self.grid.values():
            for cell in cells[1:]:
                if (
                    cell.kind == "text"
                    and cell.text in hints.base_level_only
                    and len(cell.action) == 1
                ):
                    cell.text = cell.action
        self.typed_keysyms = self._plain_keysyms()
        self.taken = set(self.typed_keysyms) | set(self.borrowed.values())
        self.dead_triggers: Dict[str, str] = {}
        # Action id -> keysyms its keys type (see _keysyms_typing_action).
        self._action_keysyms: Optional[Dict[str, List[str]]] = None

    # -- keysym choice ----------------------------------------------------

    def _plain_keysyms(self) -> set:
        typed = set()
        for cells in self.grid.values():
            for cell in cells:
                if cell.kind == "text" and len(cell.text) == 1 and cell.text not in self.borrowed:
                    typed.add(self.keysyms.get(cell.text) or unicode_keysym(cell.text))
        return typed

    def _borrow(self) -> str:
        for keysym in BORROWED_KEYSYMS:
            if keysym not in self.taken:
                self.taken.add(keysym)
                return keysym
        code = PRIVATE_USE_FIRST
        while "U%X" % code in self.taken:
            code += 1
        keysym = "U%X" % code
        self.taken.add(keysym)
        return keysym

    def text_keysym(self, text: str) -> str:
        """Keysym typing ``text``; borrows one for multi-character outputs."""
        if text in self.borrowed:
            return self.borrowed[text]
        if len(text) >= 2:
            keysym = self._borrow()
            self.borrowed[text] = keysym
            return keysym
        return self.keysyms.get(text) or unicode_keysym(text)

    def base_keysym(self, action_id: str) -> str:
        """Keysym naming the character an action types from the neutral state.

        Used for the key pressed inside a dead-key state. For a dead-key action
        this is the plain keysym of the character it types alone.
        """
        action = self.layout.actions.get(action_id)
        text = action_id
        if action is not None and len(action_id) != 1:
            output, next_state = action.whens.get("none", (None, None))
            if next_state:
                text = self.layout.terminators.get(next_state, "") or action_id
            elif output:
                text = output
        if text in self.borrowed:
            return self.borrowed[text]
        if len(text) == 1:
            return self.keysyms.get(text) or unicode_keysym(text)
        return self.keysyms.get(text, text)

    def dead_trigger(self, state: str) -> str:
        """Keysym a dead key entering ``state`` produces."""
        if state in self.dead_triggers:
            return self.dead_triggers[state]
        terminator = self.layout.terminators.get(state, "")
        keysym = None
        if terminator in self.borrowed:
            keysym = self.borrowed[terminator]
        elif "dead_" + state in KNOWN_DEAD_KEYSYMS:
            keysym = "dead_" + state
        elif terminator in DEAD_KEYSYMS_BY_TERMINATOR:
            keysym = DEAD_KEYSYMS_BY_TERMINATOR[terminator]
        elif len(terminator) == 1 and terminator in self.keysyms:
            named = self.keysyms[terminator]
            if named not in self.taken:
                keysym = named
        if keysym is None or keysym in self.dead_triggers.values():
            keysym = self._borrow()
        self.taken.add(keysym)
        self.dead_triggers[state] = keysym
        return keysym

    # -- dead-key sequences ----------------------------------------------

    def _cell_keysym(self, cell: Resolved) -> Optional[str]:
        if cell.kind == "dead":
            return self.dead_trigger(cell.state)
        if cell.kind == "text":
            return self.text_keysym(cell.text)
        return None

    def _keysyms_typing_action(self, action_id: str) -> List[str]:
        """Keysyms of every key/level whose <key> uses ``action_id``."""
        if self._action_keysyms is None:
            # One pass over the keyboard, built once every keysym is chosen
            # (after symbols()): compose() asks it for every dead-key output.
            by_action: Dict[str, List[str]] = {}
            for xkb, code in self.keycodes:
                for level, index in enumerate(self.level_indices):
                    entry = self.layout.key_entry(index, code)
                    if entry is None or entry[0] != "action":
                        continue
                    keysym = self._cell_keysym(self.grid[xkb][level])
                    found = by_action.setdefault(entry[1], [])
                    if keysym and keysym not in found:
                        found.append(keysym)
            self._action_keysyms = by_action
        return self._action_keysyms.get(action_id, [])

    def dead_sequences(self) -> Dict[str, List[List[str]]]:
        """Keysym sequences entering each dead-key state, chains included."""
        direct: Dict[str, List[List[str]]] = {}
        for cells in self.grid.values():
            for cell in cells:
                if cell.kind == "dead":
                    sequence = [self.dead_trigger(cell.state)]
                    bucket = direct.setdefault(cell.state, [])
                    if sequence not in bucket:
                        bucket.append(sequence)
        sequences = {state: list(seqs) for state, seqs in direct.items()}
        # A chained dead key is an action that, inside state P, moves to state
        # S. Iterate to a fixed point so chains of any length are found.
        changed = True
        rounds = 0
        while changed:
            rounds += 1
            if rounds > 16:
                raise KeylayoutError("dead-key chains do not terminate")
            changed = False
            for action_id in sorted(self.layout.actions):
                action = self.layout.actions[action_id]
                for state, (_output, next_state) in action.whens.items():
                    if state == "none" or not next_state or state not in sequences:
                        continue
                    for prefix in list(sequences[state]):
                        for keysym in self._keysyms_typing_action(action_id):
                            candidate = prefix + [keysym]
                            bucket = sequences.setdefault(next_state, [])
                            if candidate not in bucket:
                                bucket.append(candidate)
                                changed = True
        return sequences

    # -- output -----------------------------------------------------------

    def symbols(self, template: str, layout_id: str, display_name: str) -> str:
        text = re.sub(r'xkb_symbols\s+"[^"]+"', 'xkb_symbols "%s"' % layout_id, template)
        text = re.sub(
            r'name\[Group1\]\s*=\s*"[^"]+";',
            lambda _match: 'name[Group1] = "%s";' % display_name,
            text,
        )
        for xkb, _code in self.keycodes:
            names: List[str] = []
            comments: List[str] = []
            for cell in self.grid[xkb]:
                keysym = self._cell_keysym(cell)
                names.append(keysym or NO_SYMBOL)
                shown = cell.text if cell.kind != "none" else ""
                comments.append('"%s"' % shown if len(shown) >= 2 else shown)
            self.result.key_symbols[xkb] = names
            pattern = r"key <%s>[^\n]*;" % re.escape(xkb)
            line = 'key <%s> { type[group1] = "%s", [%s] }; // %s' % (
                xkb,
                TYPE_NAME,
                ", ".join(names),
                " ".join(comments),
            )
            text, count = re.subn(pattern, lambda _match, line=line: line, text)
            if count != 1:
                raise KeylayoutError("the symbols template has no single line for <%s>" % xkb)
        return text

    def compose(self) -> str:
        sequences = self.dead_sequences()
        self.result.dead_sequences = sequences
        dead_texts = {self.layout.terminators.get(state, "") for state in self.dead_triggers}
        lines: List[str] = []
        for text, keysym in self.borrowed.items():
            if text in dead_texts and keysym in self.dead_triggers.values():
                continue
            lines.append("<%s> : %s" % (keysym, compose_string(text)))
        lines.append("")

        outputs: Dict[str, List[Tuple[str, str]]] = {}
        for action_id, action in self.layout.actions.items():
            for state, (output, _next_state) in action.whens.items():
                if state != "none" and output:
                    outputs.setdefault(state, []).append((action_id, output))

        first = True
        emitted: Dict[str, str] = {}
        for state in sorted(outputs):
            if state not in sequences:
                continue
            for action_id, _output in sorted(outputs[state]):
                # An action no key uses cannot be typed on macOS either.
                typed = self._keysyms_typing_action(action_id)
                if typed and self.base_keysym(action_id) not in typed:
                    self.result.unreachable.append((state, action_id))
            for prefix in sequences[state]:
                if not first:
                    lines.append("")
                first = False
                head = " ".join("<%s>" % keysym for keysym in prefix)
                lines.append(
                    "%s\t: %s" % (head, compose_string(self.layout.terminators.get(state, "")))
                )
                for action_id, output in sorted(outputs[state]):
                    sequence = "%s <%s>" % (head, self.base_keysym(action_id))
                    if sequence in emitted:
                        if emitted[sequence] != output:
                            self.result.conflicts.append((sequence, emitted[sequence], output))
                        continue
                    emitted[sequence] = output
                    lines.append("%s\t: %s" % (sequence, compose_string(output)))
        return 'include "%L"\n\n' + "\n".join(lines) + "\n"


def compose_string(text: str) -> str:
    """Render ``text`` as a Compose string literal.

    Compose strings are always double-quoted; a backslash or a double quote
    inside them must be escaped or the parser reports an unterminated string
    and drops the sequences that follow.
    """
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return '"%s"' % escaped


def convert(
    keylayout_text: str,
    keycodes: Sequence[Tuple[str, int]],
    layout_id: str,
    display_name: str,
    hints: Optional[XkbHints] = None,
) -> Conversion:
    """Convert a .keylayout to XKB symbols and XCompose text.

    Args:
        keylayout_text: Content of the .keylayout.
        keycodes: (XKB key name, macOS code) pairs, see load_keycodes().
        layout_id: Name of the xkb_symbols section (no dots).
        display_name: Name shown by desktop layout pickers.
        hints: Per-layout choices from the registry index (XkbHints).
    """
    if not re.fullmatch(r"[A-Za-z0-9_]+", layout_id):
        raise KeylayoutError("layout id %r must be letters, digits and _" % layout_id)
    layout = parse_keylayout(keylayout_text)
    converter = _Converter(layout, keycodes, hints or XkbHints())
    template = (DATA_DIR / "xkb_symbols.txt").read_text(encoding="utf-8")
    # Dead triggers first, in state order, so borrowed keysyms do not depend
    # on the order keys happen to be listed in.
    for state in sorted(
        {cell.state for cells in converter.grid.values() for cell in cells if cell.kind == "dead"}
    ):
        converter.dead_trigger(state)
    result = converter.result
    result.symbols_text = converter.symbols(template, layout_id, display_name)
    result.compose_text = converter.compose()
    result.borrowed = dict(converter.borrowed)
    result.dead_triggers = dict(converter.dead_triggers)
    return result


def write_package(result: Conversion, out_dir: Path, layout_id: str) -> List[Path]:
    """Write <id>.xkb, <id>.XCompose and xkb_types.txt into ``out_dir``."""
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for name, content in (
        ("%s.xkb" % layout_id, result.symbols_text),
        ("%s.XCompose" % layout_id, result.compose_text),
    ):
        path = out_dir / name
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        written.append(path)
    types = out_dir / "xkb_types.txt"
    types.write_bytes((DATA_DIR / "xkb_types.txt").read_bytes())
    written.append(types)
    return written


def hints_from_index(index_path: Path, layout_id: str) -> XkbHints:
    """XKB hints of one registry entry (empty when it declares none)."""
    index = json.loads(Path(index_path).read_text(encoding="utf-8"))
    for entry in index["layouts"]:
        if entry["id"] == layout_id:
            return XkbHints.from_entry(entry)
    raise KeylayoutError("layout %r is not in %s" % (layout_id, index_path))


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Convert a macOS .keylayout to XKB files.")
    parser.add_argument("--keylayout", required=True, type=Path)
    parser.add_argument("--keycodes", required=True, type=Path, help="shared mac_keycodes.json")
    parser.add_argument("--convention", required=True, choices=("iso", "ansi"))
    parser.add_argument("--layout-id", required=True)
    parser.add_argument("--display-name", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument(
        "--index", type=Path, help="registry index.json carrying the layout's XKB hints"
    )
    parser.add_argument(
        "--registry-id", help="registry id to read from --index (default: --layout-id)"
    )
    args = parser.parse_args(argv)
    try:
        registry_id = args.registry_id or args.layout_id
        hints = hints_from_index(args.index, registry_id) if args.index else XkbHints()
        text = args.keylayout.read_text(encoding="utf-8")
        result = convert(
            text,
            load_keycodes(args.keycodes, args.convention),
            args.layout_id,
            args.display_name,
            hints,
        )
        for path in write_package(result, args.out, args.layout_id):
            print(path)
    except (OSError, KeylayoutError, KeyError, ValueError) as error:
        print("keylayout_to_xkb: %s" % error, file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
