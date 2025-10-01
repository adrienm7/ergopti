import html
import json
import re
from logging import getLogger
from pathlib import Path

import yaml
from data.levels import LEVELS
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

mapped_symbols = {
    "« ": "guillemotleft",
    " »": "guillemotright",
    "ᵉ": "uparrow",
    "ᵢ": "downarrow",
    "ℝ": "infinity",
}
available_symbols = UNUSED_SYMBOLS

logger = getLogger("ergopti.linux")


def generate_xkb(xkb_template, keylayout_data):
    """Génère le contenu XKB à partir du template et des données keylayout, en sous-fonctions."""
    keymaps = _extract_keymaps(keylayout_data)

    for xkb_key, macos_code in LINUX_TO_MACOS_KEYCODES:
        symbols, comment_symbols = _generate_symbols_and_comments(
            xkb_key,
            macos_code,
            keymaps,
        )
        pattern = rf"key {re.escape(xkb_key)}[^\n]*;"
        comment = " // " + " ".join(comment_symbols)
        replacement = f'key {xkb_key} {{ type[group1] = "SEVEN_LEVEL_KEY", [{", ".join(symbols)}] }};{comment}'
        xkb_template = re.sub(pattern, replacement, xkb_template)
    return xkb_template, mapped_symbols


def _extract_keymaps(keylayout_data):
    logger.info("Extracting keymaps from <keyMapSet id='ISO'>...")
    keymaps = [
        extract_keymap_body(keylayout_data, i, keymapset_id="ISO")
        for i in [
            LEVELS["Base"],
            LEVELS["CapsLock"],
            LEVELS["Shift"],
            LEVELS["CapsLock + Shift"],
            LEVELS["Modifiers"],
            LEVELS["AltGr"],
            LEVELS["Shift + AltGr"],
        ]
    ]
    return keymaps


def _generate_symbols_and_comments(
    xkb_key,
    macos_code,
    keymaps,
):
    logger.info("Generating for key %s", xkb_key)
    symbols = []
    comment_symbols = []
    for layer, keymap_body in enumerate(keymaps):
        symbol = get_symbol(keymap_body, macos_code)
        linux_name = _get_linux_name_and_comment(
            symbol,
            layer,
        )
        symbols.append(linux_name)
        if len(symbol) >= 2:
            comment_symbols.append(f'"{symbol}"')
        else:
            comment_symbols.append(symbol)
    return symbols, comment_symbols


def _get_linux_name_and_comment(
    symbol,
    layer,
):
    """Convert a symbol to its XKB keysym name using direct character keys from the YAML mapping."""
    # Already defined cases
    if symbol in mapped_symbols:
        return mapped_symbols[symbol]

    if len(symbol) >= 2:
        if not available_symbols:
            raise RuntimeError(
                "Plus de symboles inutilisés disponibles pour le mapping."
            )
        linux_name = sorted(available_symbols)[0]
        mapped_symbols[symbol] = linux_name
        available_symbols.remove(linux_name)
        return linux_name

    # Default mapping with explicit unicode symbol handling
    decoded = html.unescape(symbol)
    linux_name = "NoSymbol"
    for char in decoded:
        unicode_key = f"U{ord(char):04X}"
        if char in mappings:
            # If it's a dead key, map accordingly
            linux_name = mappings[char]
            if (
                linux_name == "asciicircum"
                and not layer == LEVELS["AltGr"]
                and not layer == LEVELS["Modifiers"]
            ):
                linux_name = "dead_circumflex"
            if linux_name == "diaeresis" and not layer == LEVELS["Modifiers"]:
                linux_name = "dead_diaeresis"
            if linux_name == "currency" and not layer == LEVELS["Modifiers"]:
                linux_name = "dead_currency"

        else:
            logger.warning(
                f"No mapping for {repr(char)} (U+{ord(char):04X}), using Unicode codepoint."
            )
            linux_name = unicode_key

    return linux_name
