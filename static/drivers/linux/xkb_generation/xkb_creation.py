import html
import json
import re
from logging import getLogger
from pathlib import Path

import yaml
from data.unused_symbols import UNUSED_SYMBOLS
from utilities.information_extraction import (
    extract_keymap_body,
    get_symbol,
)

data_dir = Path(__file__).parent / "data"
LINUX_TO_MACOS_KEYCODES = json.loads(
    (data_dir / "linux_to_macos_keycodes.json").read_text(encoding="utf-8")
)
mappings = yaml.safe_load(
    (data_dir / "key_sym.yaml").read_text(encoding="utf-8")
)

logger = getLogger("ergopti.linux")


def generate_xkb(xkb_template, keylayout_data):
    """Génère le contenu XKB à partir du template et des données keylayout, en sous-fonctions."""
    keymaps = _extract_keymaps(keylayout_data)
    used_symbols = {}
    fraction_idx = 0
    for xkb_key, macos_code in LINUX_TO_MACOS_KEYCODES:
        symbols, comment_symbols, fraction_idx = _generate_symbols_and_comments(
            xkb_key,
            macos_code,
            keymaps,
            used_symbols,
            fraction_idx,
        )
        pattern = rf"key {re.escape(xkb_key)}[^\n]*;"
        quoted_symbols = _apply_special_cases(xkb_key, symbols)
        comment = " // " + " ".join(comment_symbols)
        replacement = f'key {xkb_key} {{ type[group1] = "FOUR_LEVEL_SEMIALPHABETIC_CONTROL", [{", ".join(quoted_symbols)}] }};{comment}'
        xkb_template = re.sub(pattern, replacement, xkb_template)
    return xkb_template, used_symbols


def _extract_keymaps(keylayout_data):
    logger.info(
        "Extracting keymaps for layers 0, 2, 5, 6, 4, 4 from <keyMapSet id='ISO'>..."
    )
    keymaps = [
        extract_keymap_body(keylayout_data, i, keymapset_id="ISO")
        for i in [0, 2, 5, 6, 4]
    ]
    keymaps.append(keymaps[4])
    return keymaps


def _generate_symbols_and_comments(
    xkb_key,
    macos_code,
    keymaps,
    used_symbols,
    fraction_idx,
):
    logger.info("Generating for key %s", xkb_key)
    symbols = []
    comment_symbols = []
    for layer, keymap_body in enumerate(keymaps):
        symbol = get_symbol(keymap_body, macos_code)
        linux_name, fraction_idx = _get_linux_name_and_comment(
            symbol,
            layer,
            used_symbols,
            fraction_idx,
        )
        symbols.append(linux_name)
        if len(symbol) >= 2:
            comment_symbols.append(f'"{symbol}"')
        else:
            comment_symbols.append(symbol)
    return symbols, comment_symbols, fraction_idx


def _get_linux_name_and_comment(
    symbol,
    layer,
    used_symbols,
    fraction_idx,
):
    """Convert a symbol to its XKB keysym name using direct character keys from the YAML mapping."""

    linux_name = "NoSymbol"

    # Special cases
    if symbol == "«" and layer == 4:
        linux_name = "guillemotleft"
    if symbol == "»" and layer == 4:
        linux_name = "guillemotright"
    if symbol == "ᵉ":
        linux_name = "uparrow"
    if symbol == "ᵢ":
        linux_name = "downarrow"
    if symbol == "ℝ":
        linux_name = "infinity"

    if linux_name != "NoSymbol":
        return linux_name, fraction_idx

    if len(symbol) >= 2:
        frac = UNUSED_SYMBOLS[fraction_idx % len(UNUSED_SYMBOLS)]
        if frac not in used_symbols:
            used_symbols[frac] = symbol
        linux_name = mappings.get(frac, f"U{ord(frac):04X}")
        return linux_name, fraction_idx + 1

    # Default mapping with explicit unicode symbol handling
    decoded = html.unescape(symbol)
    for char in decoded:
        unicode_key = f"U{ord(char):04X}"
        if char in mappings:
            # If it's a dead key, map accordingly
            linux_name = mappings[char]
            if linux_name == "asciicircum" and not layer == 4:
                linux_name = "dead_circumflex"
            if linux_name == "diaeresis":
                linux_name = "dead_diaeresis"
            if linux_name == "currency":
                linux_name = "dead_currency"

        else:
            logger.warning(
                f"No mapping for {repr(char)} (U+{ord(char):04X}), using Unicode codepoint."
            )
            linux_name = unicode_key

    return linux_name, fraction_idx


def _apply_special_cases(xkb_key, symbols):
    """
    Apply special substitution rules for certain XKB keys.
    Always use 'U2792' for the last two positions of <AD12>.
    """
    # Special case for <BKSL>
    if xkb_key == "<BKSL>":
        result = []
        for i, s in enumerate(symbols):
            if i == 0:
                result.append("dead_circumflex")
            elif s == "dead_circumflex":
                result.append("asciicircum")
            else:
                result.append(s)
        return result

    # Special case for <LSGT>
    if xkb_key == "<LSGT>":
        result = []
        for i, s in enumerate(symbols):
            if i == 2 and s == "dead_circumflex":
                result.append("asciicircum")
            elif i == 3 and s == "dead_circumflex":
                result.append("dead_circumflex")
            else:
                result.append(s)
        return result

    # Special case for <AD12>
    if xkb_key == "<AD12>":
        quoted_symbols = []
        for i, s in enumerate(symbols):
            # First position: dead_diaeresis if U2792 or diaeresis
            if i == 0 and s in ("U2792", "diaeresis"):
                quoted_symbols.append("dead_diaeresis")
            else:
                quoted_symbols.append(s)
        # Replace dead_currency if U20B0
        quoted_symbols = [
            "dead_currency" if s == "U20B0" else s for s in quoted_symbols
        ]
        # Always force U2792 for the last two positions
        if len(quoted_symbols) >= 2:
            quoted_symbols[-2] = "U2792"
            quoted_symbols[-1] = "U2792"
        return quoted_symbols

    return symbols
