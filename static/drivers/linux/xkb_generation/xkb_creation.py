import html
import json
import os
import re
from logging import getLogger

import yaml
from data.unused_symbols import UNUSED_SYMBOLS
from utilities.information_extraction import (
    extract_keymap_body,
    get_symbol,
)

try:
    from lxml import etree as LET
except ImportError:
    LET = None

with open(
    os.path.join(
        os.path.dirname(__file__), "data", "linux_to_macos_keycodes.json"
    ),
    "r",
    encoding="utf-8",
) as keycodes_file:
    LINUX_TO_MACOS_KEYCODES = json.load(keycodes_file)

yaml_path = os.path.join(os.path.dirname(__file__), "data", "key_sym.yaml")
with open(yaml_path, encoding="utf-8") as yaml_file:
    mappings = yaml.safe_load(yaml_file)

logger = getLogger("ergopti.linux")


def generate_xkb(xkb_template, keylayout_data):
    """Génère le contenu XKB à partir du template et des données keylayout, en sous-fonctions."""
    keymaps = _extract_keymaps(keylayout_data)
    fraction_map = {}
    fraction_idx = 0
    for xkb_key, macos_code in LINUX_TO_MACOS_KEYCODES:
        symbols, comment_symbols, fraction_idx = _generate_symbols_and_comments(
            xkb_key,
            macos_code,
            keymaps,
            fraction_map,
            fraction_idx,
        )
        generate_xkb.fraction_map = fraction_map
        pattern = rf"key {re.escape(xkb_key)}[^\n]*;"
        quoted_symbols = _apply_special_cases(xkb_key, symbols)
        comment = " // " + " ".join(comment_symbols)
        replacement = f'key {xkb_key} {{ type[group1] = "FOUR_LEVEL_SEMIALPHABETIC_CONTROL", [{", ".join(quoted_symbols)}] }};{comment}'
        xkb_template = re.sub(pattern, replacement, xkb_template)
    return xkb_template


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
    fraction_map,
    fraction_idx,
):
    symbols = []
    comment_symbols = []
    for layer, keymap_body in enumerate(keymaps):
        symbol = get_symbol(keymap_body, macos_code)
        linux_name, comment_symbol, fraction_idx = _get_linux_name_and_comment(
            symbol,
            layer,
            fraction_map,
            fraction_idx,
        )
        symbols.append(linux_name)
        if comment_symbol is not None:
            comment_symbols.append(comment_symbol)
        elif symbol:
            decoded = html.unescape(symbol)
            if len(decoded) > 1:
                comment_symbols.append(f'"{decoded}"')
            else:
                comment_symbols.append(decoded)
        else:
            comment_symbols.append("")
    return symbols, comment_symbols, fraction_idx


def _get_linux_name_and_comment(
    symbol,
    layer,
    fraction_map,
    fraction_idx,
):
    """Convert a symbol to its XKB keysym name using direct character keys from the YAML mapping."""

    linux_name = "NoSymbol"
    if not symbol or symbol == "NoSymbol":
        return "NoSymbol", None, fraction_idx

        # Cas spéciaux pour les guillemets
    if symbol == "«" and layer == 4:
        return "guillemotleft", None, fraction_idx
    if symbol == "»" and layer == 4:
        return "guillemotright", None, fraction_idx

    if len(symbol) >= 2 and symbol not in ("«", "»"):
        frac = UNUSED_SYMBOLS[fraction_idx % len(UNUSED_SYMBOLS)]
        if frac not in fraction_map:
            fraction_map[frac] = symbol
        linux_name = mappings.get(frac, f"U{ord(frac):04X}")
        return linux_name, f'"{symbol}"', fraction_idx + 1

    # Default mapping with explicit unicode symbol handling
    decoded = html.unescape(symbol)
    symbol_map = {
        "U27E7": "infinity",
        "U211D": "infinity",
    }
    for char in decoded:
        # Force uparrow/downarrow for ᵉ/ᵢ or U+02FA/U+02FC
        if ord(char) in (0x02FA, 0x1D49):  # ᵉ
            linux_name = "uparrow"
            continue
        if ord(char) in (0x02FC, 0x1D62):  # ᵢ
            linux_name = "downarrow"
            continue
        unicode_key = f"U{ord(char):04X}"
        if unicode_key in symbol_map:
            linux_name = symbol_map[unicode_key]
            continue
        if char in mappings:
            linux_name = mappings[char]
            # If it's a dead key, map accordingly
            if linux_name == "diaeresis":
                linux_name = "dead_diaeresis"
            if linux_name == "asciicircum":
                linux_name = "dead_circumflex"
        else:
            print(
                f"[WARNING] No mapping for {repr(char)} (U+{ord(char):04X}), using Unicode codepoint."
            )
            linux_name = unicode_key

    if linux_name == "currency":
        linux_name = "dead_currency"
    if linux_name == "dead_circumflex" and layer == 4:
        linux_name = "asciicircum"

    # uparrow/downarrow spéciaux
    if symbol and (any(ord(c) in (0x02FA, 0x1D49) for c in symbol)):
        linux_name = "uparrow"
    if symbol and (any(ord(c) in (0x02FC, 0x1D62) for c in symbol)):
        linux_name = "downarrow"

    return linux_name, None, fraction_idx


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
