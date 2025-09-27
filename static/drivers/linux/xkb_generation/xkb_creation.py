import html
import json
import os
import re
from logging import getLogger

import yaml
from utilities.information_extraction import (
    build_deadkey_symbol_map,
    extract_deadkey_triggers,
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
    # Extract keymaps (0, 2, 5, 6, 4, 4) from the ISO keyMapSet
    logger.info(
        "Extracting keymaps for layers 0, 2, 5, 6, 4, 4 from <keyMapSet id='ISO'>..."
    )
    keymaps = [
        extract_keymap_body(keylayout_data, i, keymapset_id="ISO")
        for i in [0, 2, 5, 6, 4]
    ]
    keymaps.append(keymaps[4])

    # Deadkey extraction
    logger.info("Building deadkey trigger map...")
    deadkey_triggers = extract_deadkey_triggers(keylayout_data)

    # deadkey_name -> unicode_symbol
    logger.info("Building deadkey symbol map...")
    deadkey_symbol_map = build_deadkey_symbol_map(keylayout_data)

    # Liste des fractions Unicode à utiliser pour les substitutions multi-caractères
    fraction_symbols = [
        "⅓",
        "⅔",
        "⅕",
        "⅖",
        "⅗",
        "⅘",
        "⅙",
        "⅚",
        "⅛",
        "⅜",
        "⅝",
        "⅞",
    ]
    fraction_map = {}  # fraction_symbol -> original sequence
    fraction_idx = 0
    for xkb_key, macos_code in LINUX_TO_MACOS_KEYCODES:
        symbols = []
        comment_symbols = []
        comment_symbol = None
        for layer, keymap_body in enumerate(keymaps):
            symbol = get_symbol(keymap_body, macos_code)
            # Correction : ne remplacer que la couche 5 si « ou »
            # Cas particulier : forcer « et » sur la couche 5
            if layer == 4 and symbol == "«":
                linux_name = mappings.get("«", "guillemotleft")
                symbols.append(linux_name)
                comment_symbols.append("«")
                continue
            if layer == 4 and symbol == "»":
                linux_name = mappings.get("»", "guillemotright")
                symbols.append(linux_name)
                comment_symbols.append("»")
                continue
            # Substitution fraction généralisée pour tout symbole multi-caractère sauf « et »
            if symbol and len(symbol) >= 2 and symbol not in ("«", "»"):
                frac = fraction_symbols[fraction_idx % len(fraction_symbols)]
                if frac not in fraction_map:
                    fraction_map[frac] = symbol
                linux_name = mappings.get(frac, f"U{ord(frac):04X}")
                symbols.append(linux_name)
                comment_symbols.append(f'"{symbol}"')
                fraction_idx += 1
                continue
            # Gestion deadkey pour currency et asciicircum
            if symbol in deadkey_triggers:
                deadkey_name = deadkey_triggers[symbol]
                if deadkey_symbol_map and deadkey_name in deadkey_symbol_map:
                    unicode_sym = deadkey_symbol_map[deadkey_name]
                    xkb_name = mappings.get(unicode_sym)
                    if xkb_name == "currency":
                        linux_name = "dead_currency"
                    elif xkb_name == "asciicircum":
                        # Couche 5 : forcer le ^ normal
                        if layer == 4:
                            linux_name = "asciicircum"
                        else:
                            linux_name = "dead_circumflex"
                    elif xkb_name:
                        linux_name = f"deadkey_{xkb_name}"
                    else:
                        if unicode_sym and len(unicode_sym) > 0:
                            linux_name = f"U{ord(unicode_sym[0]):04X}"
                        else:
                            linux_name = "NoSymbol"
                else:
                    linux_name = deadkey_name
            else:
                # Forcer uparrow/downarrow pour U+02FA/U+1D49 et U+02FC/U+1D62
                comment_symbol = None
                if symbol and (any(ord(c) in (0x02FA, 0x1D49) for c in symbol)):
                    linux_name = "uparrow"
                    comment_symbol = "ᵉ"
                elif symbol and (
                    any(ord(c) in (0x02FC, 0x1D62) for c in symbol)
                ):
                    linux_name = "downarrow"
                    comment_symbol = "ᵢ"
                else:
                    linux_name = symbol_to_linux_name(symbol)
                    if linux_name == "currency":
                        linux_name = "dead_currency"
                # Si le symbole est ^ (asciicircum) sur la couche 5, forcer le normal
                if linux_name == "dead_circumflex" and layer == 4:
                    linux_name = "asciicircum"
            symbols.append(linux_name)
            # Remplacement du commentaire pour uparrow/downarrow
            if comment_symbol:
                comment_symbols.append(comment_symbol)
            elif symbol:
                decoded = html.unescape(symbol)
                if len(decoded) > 1:
                    comment_symbols.append(f'"{decoded}"')
                else:
                    comment_symbols.append(decoded)
            else:
                comment_symbols.append("")
        # Stocke le mapping pour XCompose (après la boucle sur les layers)
        generate_xkb.fraction_map = fraction_map
        pattern = rf"key {re.escape(xkb_key)}[^\n]*;"

        # Remplacement final dans la ligne XKB : U02FA → uparrow, U02FC → downarrow
        # Correction spéciale pour <BKSL> : deadkey uniquement en 1ère position, sinon asciicircum
        if xkb_key == "<BKSL>":
            quoted_symbols = [
                "dead_circumflex"
                if i == 0
                else "asciicircum"
                if s == "dead_circumflex"
                else s
                for i, s in enumerate(symbols)
            ]
        elif xkb_key == "<LSGT>":
            quoted_symbols = [
                s
                if i not in (2, 3)
                else ("asciicircum" if i == 2 else "dead_circumflex")
                if s == "dead_circumflex"
                else s
                for i, s in enumerate(symbols)
            ]
        elif xkb_key == "<AD12>":
            quoted_symbols = [
                "dead_diaeresis"
                if i == 0 and s in ("U2792", "diaeresis")
                else s
                for i, s in enumerate(symbols)
            ]
            quoted_symbols = [
                "dead_currency" if s == "U20B0" else s for s in quoted_symbols
            ]
            # Correction : pour les deux dernières positions, forcer U2792
            if len(quoted_symbols) >= 6:
                quoted_symbols[-2] = "U2792"
                quoted_symbols[-1] = "U2792"
        else:
            symbol_map = {
                "U02FA": "uparrow",
                "U02FC": "downarrow",
                "U27E7": "infinity",
                "U20B0": "dead_currency",
                "U211D": "infinity",
            }
            quoted_symbols = [symbol_map.get(s, s) for s in symbols]

        comment = " // " + " ".join(comment_symbols)
        replacement = f'key {xkb_key} {{ type[group1] = "FOUR_LEVEL_SEMIALPHABETIC_CONTROL", [{", ".join(quoted_symbols)}] }};{comment}'
        xkb_template = re.sub(pattern, replacement, xkb_template)
    return xkb_template


def symbol_to_linux_name(symbol):
    """Convert a symbol to its XKB keysym name using direct character keys from the YAML mapping."""
    if not symbol or symbol == "NoSymbol":
        return "NoSymbol"

    decoded = html.unescape(symbol)
    for char in decoded:
        # Force uparrow/downarrow for ᵉ/ᵢ or U+02FA/U+02FC
        if ord(char) in (0x02FA, 0x1D49):  # ᵉ
            return "uparrow"
        if ord(char) in (0x02FC, 0x1D62):  # ᵢ
            return "downarrow"
        if char in mappings:
            mapped = mappings[char]
            # Correction : si c'est une touche morte, renvoyer dead_diaeresis ou dead_circumflex
            if mapped == "diaeresis":
                return "dead_diaeresis"
            if mapped == "asciicircum":
                return "dead_circumflex"
            return mapped
        else:
            print(
                f"[WARNING] No mapping for {repr(char)} (U+{ord(char):04X}), using Unicode codepoint."
            )
            return f"U{ord(char):04X}"
    return "NoSymbol"
