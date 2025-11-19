import json
import re
import sys
from logging import getLogger
from pathlib import Path
from typing import Any, Dict, List, Tuple

import yaml

# Load data modules directly
script_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(script_dir / "data"))
sys.path.insert(0, str(script_dir.parent))

from levels import LEVELS
from unused_symbols import UNUSED_SYMBOLS
from utilities.keylayout_extraction import (
    extract_keymap_body,
    extract_actions_body,
    get_symbol,
)

data_dir: Path = Path(__file__).parent / "data"
LINUX_TO_MACOS_KEYCODES: list[Tuple[str, str]] = json.loads(
    (data_dir / "linux_to_macos_keycodes.json").read_text(encoding="utf-8")
)
key_sym: Dict[str, str] = yaml.safe_load(
    (data_dir / "key_sym.yaml").read_text(encoding="utf-8")
)

mapped_symbols: Dict[str, str] = {
    "« ": "guillemotleft",
    " »": "guillemotright",
    "ᵉ": "uparrow",
    "ᵢ": "downarrow",
    "ℝ": "infinity",
}
available_symbols: set[str] = set(UNUSED_SYMBOLS)

logger = getLogger("ergopti.linux")


def generate_xkb(
    xkb_template: str, keylayout_data: str
) -> Tuple[str, Dict[str, str]]:
    """Generates XKB content from the template and keylayout data.

    Args:
        xkb_template: The XKB template to modify.
        keylayout_data: The keylayout XML data.

    Returns:
        A tuple (new_template, mapped_symbols).

    Example:
        new_xkb, mapping = generate_xkb(template, xml_data)
    """
    keymaps: List[Any] = extract_keymaps(keylayout_data)
    actions_body = extract_actions_body(keylayout_data)

    for xkb_key, macos_code in LINUX_TO_MACOS_KEYCODES:
        symbols, comment_symbols = generate_symbols_and_comments(
            xkb_key,
            macos_code,
            keymaps,
            actions_body,
        )
        pattern = rf"key {re.escape(xkb_key)}[^\n]*;"
        comment = " // " + " ".join(comment_symbols)
        replacement = (
            f'key {xkb_key} {{ type[group1] = "SEVEN_LEVEL_KEY", '
            f"[{', '.join(symbols)}] }};{comment}"
        )
        xkb_template = re.sub(pattern, replacement, xkb_template)
    return xkb_template, mapped_symbols


def extract_keymaps(keylayout_data: str) -> List[Any]:
    """Extracts keymaps from the keylayout XML for each level.

    Args:
        keylayout_data: The keylayout XML data.

    Returns:
        List of keymaps for each level.
    """
    logger.info("Extracting keymaps…")
    keymaps = [
        extract_keymap_body(keylayout_data, i)
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


def generate_symbols_and_comments(
    xkb_key: str,
    macos_code: str,
    keymaps: List[Any],
    actions_body: str,
) -> Tuple[List[str], List[str]]:
    """Generates the list of XKB symbols and comments for a given key.

    Args:
        xkb_key: XKB key name.
        macos_code: Associated macOS code.
        keymaps: List of keymaps for each level.

    Returns:
        Tuple (list of symbols, list of comments).
    """
    logger.info("Generating for key %s", xkb_key)
    symbols: List[str] = []
    comment_symbols: List[str] = []
    for layer, keymap_body in enumerate(keymaps):
        symbol = get_symbol(keymap_body, macos_code, actions_body)
        if layer != 0 and macos_code == 8 and symbol == "★":
            symbol = "j"
        linux_name = get_linux_name_from_output(
            symbol,
            layer,
        )
        symbols.append(linux_name)
        if len(symbol) >= 2:
            comment_symbols.append(f'"{symbol}"')
        else:
            comment_symbols.append(symbol)
    return symbols, comment_symbols


def get_linux_name_from_output(
    symbol: str,
    layer: int,
) -> str:
    """Converts a symbol to XKB keysym name using YAML mapping and deadkey rules.

    Args:
        symbol: The character to convert.
        layer: The level index.

    Returns:
        The corresponding XKB keysym name.
    """
    if not symbol or symbol == "":
        return "NoSymbol"

    # Already mapped cases
    if symbol in mapped_symbols:
        return mapped_symbols[symbol]

    if len(symbol) >= 2:
        if not available_symbols:
            raise RuntimeError("No unused symbols available for mapping.")
        linux_name = sorted(available_symbols)[0]
        mapped_symbols[symbol] = linux_name
        available_symbols.remove(linux_name)
        return linux_name

    if symbol in key_sym:
        # Deadkey mapping
        linux_name = key_sym[symbol]
        if (
            linux_name == "asciicircum"
            and layer != LEVELS["AltGr"]
            and layer != LEVELS["Modifiers"]
        ):
            linux_name = "dead_circumflex"
        if linux_name == "diaeresis" and layer != LEVELS["Modifiers"]:
            linux_name = "dead_diaeresis"
        if linux_name == "currency" and layer != LEVELS["Modifiers"]:
            linux_name = "dead_currency"
        return linux_name
    else:
        logger.warning("No mapping for %s, using Unicode codepoint…", symbol)
        unicode_key = f"U{ord(symbol):04X}"
        linux_name = unicode_key
        return linux_name
