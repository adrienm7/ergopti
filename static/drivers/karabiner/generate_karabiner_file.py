"""Generate Karabiner roll rules for Ergopti(+).

Extract key positions from the macOS .keylayout file, build roll / dead-key
manipulators based on the Ergopti+ mapping hotstrings, and export:
    - rolls.json: raw list of rules grouped by trigger mapping
    - rolls_grouped.json: rules regrouped by originating key
    - karabiner.json: merged hotstrings (by adding those rules to base file)

Multi-key output symbols (e.g. '➜') are represented as ordered sequences of
key positions.
"""

import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Union

sys.path.append(str(Path(__file__).parent.parent.resolve()))
from utilities.keylayout_extraction import extract_keymap_body
from utilities.mappings_functions import (
    unescape_xml_characters,
)
from utilities.rolls_mappings import (
    PLUS_MAPPINGS_CONFIG,
    add_case_sensitive_mappings,
)

REPEAT_KEY = False
plus_mappings = add_case_sensitive_mappings(PLUS_MAPPINGS_CONFIG)


def is_trigger_shifted(trigger: str) -> bool:
    """Detect if a trigger is a 'shifted' version (uppercase equivalent).

    Special cases:
    - Triggers with espace insécable ( ) + punctuation are considered shifted
    - Triggers with espace fine insécable ( ) + punctuation are considered shifted
    - Normal uppercase letters are considered shifted
    """
    if not trigger:
        return False

    # Check for espace insécable or espace fine insécable + punctuation patterns (these are "shifted" versions)
    if len(trigger) >= 2 and trigger[0] in [
        " ",
        " ",
    ]:  # espace insécable or espace fine insécable
        return True

    # Check for normal uppercase letters
    if len(trigger) > 0 and trigger[0].isupper():
        return True

    return False


# A key position is simply a dict: {"keycode": int, "layer": int}
# A sequence is a list of such dicts
KeySequence = List[dict]
KeycodeMap = Dict[str, List[Union[dict, KeySequence]]]


def get_keycode_map(keylayout_path: str) -> KeycodeMap:
    """Build a map of symbol -> list of key positions (single or sequences).

    Each entry value is a list because a symbol may exist at several physical
    positions (different layers) and a position can itself be a multi-key
    sequence (represented as a list) when needed.
    """
    keycode_map: KeycodeMap = defaultdict(list)
    with open(keylayout_path, encoding="utf-8") as f:
        content = f.read()
        for layer_index in [0, 2, 5, 6]:
            keymap_content = extract_keymap_body(content, layer_index)
            for match in re.finditer(
                r'<key code="(\d+)" (action|output)="([^"]+)"',
                keymap_content,
            ):
                code = int(match.group(1))
                if code > 50:
                    continue
                output = match.group(3)
                if output:
                    keycode_map[output].append(
                        {"keycode": code, "layer": layer_index}
                    )

    # Manual multi-key entry for '➜'
    keycode_map["➜"] = [
        [
            {"keycode": 42, "layer": 1},
            {"keycode": 9, "layer": 1},
        ]
    ]
    return dict(keycode_map)


def get_macos_keylayout_path() -> Path:
    """
    Return the absolute path to the macOS keylayout file.
    Find the most recent bundle and use the _plus variant.

    Returns:
        Path: Path to the macOS keylayout _plus file.

    Raises:
        FileNotFoundError: If no keylayout file is found.
    """
    macos_dir = Path(__file__).parent.parent / "macos"
    if not macos_dir.is_dir():
        raise FileNotFoundError(f"macos directory does not exist: {macos_dir}")

    # Check for bundle directories
    bundle_dirs = list(macos_dir.glob("*.bundle"))
    if bundle_dirs:
        # Sort bundles by version to get the most recent one
        def extract_version(bundle_path: Path) -> tuple:
            """Extract version numbers from bundle name for sorting."""
            import re

            match = re.search(r"v?(\d+)\.(\d+)\.(\d+)", bundle_path.name)
            if match:
                return tuple(int(x) for x in match.groups())
            return (0, 0, 0)  # fallback for unversioned bundles

        # Sort by version (highest first)
        bundle_dirs.sort(key=extract_version, reverse=True)

        for bundle_dir in bundle_dirs:
            bundle_resources = bundle_dir / "Contents" / "Resources"
            if bundle_resources.is_dir():
                # Look specifically for _plus keylayout file (not plus_plus)
                plus_files = [
                    f
                    for f in bundle_resources.glob("*_plus.keylayout")
                    if not f.stem.endswith("_plus_plus")
                ]
                if plus_files:
                    return plus_files[0]

    # Fallback: look in main macos directory for _plus files
    plus_files = [
        f
        for f in macos_dir.glob("*_plus.keylayout")
        if not f.stem.endswith("_plus_plus")
    ]
    if plus_files:
        return plus_files[0]

    raise FileNotFoundError(f"No _plus keylayout file found in {macos_dir}")


keylayout_path = get_macos_keylayout_path()
keycode_map = get_keycode_map(str(keylayout_path))

keycode_map = {unescape_xml_characters(k): v for k, v in keycode_map.items()}

letter_to_num: dict[str, List[tuple[int, int]]] = defaultdict(list)
multi_sequences: dict[str, List[List[tuple[int, int]]]] = defaultdict(list)
num_to_letter: dict[tuple[int, int], List[str]] = defaultdict(list)

for symbol, positions in keycode_map.items():
    for pos in positions:
        if isinstance(pos, list):  # multi-key sequence
            sequence = [(p["keycode"], p["layer"]) for p in pos]
            multi_sequences[symbol].append(sequence)
            continue
        letter_to_num[symbol].append((pos["keycode"], pos["layer"]))
        num_to_letter[(pos["keycode"], pos["layer"])].append(symbol)


output_path = Path(__file__).parent / "rolls.json"
rolls = []

with open(
    Path(__file__).parent / "data" / "macos_keycodes.json", encoding="utf-8"
) as f:
    macos_keycodes = json.load(f)

for mapping_name, mapping in plus_mappings.items():
    trigger = mapping["trigger"]
    manipulators = []
    for trigger_code, trigger_layer in letter_to_num.get(trigger.lower(), []):
        trigger_name = macos_keycodes.get(str(trigger_code), trigger_code)
        # For each (second_key, output) pair
        for second_key, output in mapping["map"]:
            for second_code, second_layer in letter_to_num.get(
                second_key.lower(), []
            ):
                second_name = macos_keycodes.get(str(second_code), second_code)
                to_list = []
                to_list.append(
                    {
                        "set_variable": {
                            "name": "previous_key",
                            "value": "none",
                        }
                    }
                )
                for _ in range(len(trigger)):
                    to_list.append({"key_code": "delete_or_backspace"})

                # Layer-based modifiers
                modifiers = []
                if second_layer == 2:
                    modifiers.append("shift")
                elif second_layer == 5:
                    modifiers.append("option")
                elif second_layer == 6:
                    modifiers.extend(["shift", "option"])
                if second_key.isupper() and "shift" not in modifiers:
                    modifiers.append("shift")

                if modifiers:
                    from_block = {
                        "key_code": second_name,
                        "modifiers": {"mandatory": modifiers},
                    }
                else:
                    from_block = {"key_code": second_name}

                # Find the index of the first letter in output for shift application
                first_letter_index = None
                for idx, c in enumerate(output):
                    if c.isalpha():
                        first_letter_index = idx
                        break

                for i, char in enumerate(output):
                    char_base = char.lower()

                    # Cas général pour voyelles circonflexes : deadkey + voyelle de base
                    circonflexes = {
                        "â": "a",
                        "ê": "e",
                        "î": "i",
                        "ô": "o",
                        "û": "u",
                        "Â": "a",
                        "Ê": "e",
                        "Î": "i",
                        "Ô": "o",
                        "Û": "u",
                    }
                    if char in circonflexes:
                        # Envoyer backslash (touche morte ^) puis la voyelle de base
                        to_list.append({"key_code": "backslash"})

                        # Envoyer la touche de base (a, e, i, o, u) du layout Ergopti
                        base_vowel = circonflexes[char]
                        base_positions = letter_to_num.get(base_vowel, [])
                        if base_positions:
                            base_code, base_layer = base_positions[0]
                            base_name = macos_keycodes.get(
                                str(base_code), base_code
                            )
                            base_modifiers: List[str] = []
                            if base_layer == 2:
                                base_modifiers.append("shift")
                            elif base_layer == 5:
                                base_modifiers.append("option")
                            elif base_layer == 6:
                                base_modifiers.extend(["shift", "option"])
                            # Shift logic pour voyelles circonflexes
                            if (
                                second_layer == 2
                                or is_trigger_shifted(trigger)
                                or char.isupper()
                            ) and "shift" not in base_modifiers:
                                base_modifiers.append("shift")
                            if base_modifiers:
                                to_list.append(
                                    {
                                        "key_code": base_name,
                                        "modifiers": base_modifiers,
                                    }
                                )
                            else:
                                to_list.append({"key_code": base_name})
                        continue

                    # Cas particulier pour œ/Œ : touche morte circonflexe + o/O
                    if char in ["œ", "Œ"]:
                        # Envoyer backslash (touche morte ^) puis la touche o
                        to_list.append({"key_code": "backslash"})

                        # Envoyer la touche 'o' du layout Ergopti
                        o_positions = letter_to_num.get("o", [])
                        if o_positions:
                            o_code, o_layer = o_positions[0]
                            o_name = macos_keycodes.get(str(o_code), o_code)
                            o_modifiers: List[str] = []
                            if o_layer == 2:
                                o_modifiers.append("shift")
                            elif o_layer == 5:
                                o_modifiers.append("option")
                            elif o_layer == 6:
                                o_modifiers.extend(["shift", "option"])
                            # Shift logic pour œ/Œ
                            if (
                                second_layer == 2
                                or is_trigger_shifted(trigger)
                                or char.isupper()
                            ) and "shift" not in o_modifiers:
                                o_modifiers.append("shift")
                            if o_modifiers:
                                to_list.append(
                                    {
                                        "key_code": o_name,
                                        "modifiers": o_modifiers,
                                    }
                                )
                            else:
                                to_list.append({"key_code": o_name})
                        continue

                    # Cas particulier pour ç/Ç : touche morte circonflexe + c/C
                    if char in ["ç", "Ç"]:
                        # Envoyer backslash (touche morte ^)
                        to_list.append({"key_code": "backslash"})

                        # Envoyer la touche 'c' du layout Ergopti
                        c_positions = letter_to_num.get("c", [])
                        if c_positions:
                            c_code, c_layer = c_positions[0]
                            c_name = macos_keycodes.get(str(c_code), c_code)
                            c_modifiers: List[str] = []
                            if c_layer == 2:
                                c_modifiers.append("shift")
                            elif c_layer == 5:
                                c_modifiers.append("option")
                            elif c_layer == 6:
                                c_modifiers.extend(["shift", "option"])
                            # Shift logic for ç/Ç
                            if (
                                second_layer == 2
                                or is_trigger_shifted(trigger)
                                or char.isupper()
                            ) and "shift" not in c_modifiers:
                                c_modifiers.append("shift")
                            if c_modifiers:
                                to_list.append(
                                    {
                                        "key_code": c_name,
                                        "modifiers": c_modifiers,
                                    }
                                )
                            else:
                                to_list.append({"key_code": c_name})
                        continue

                    # Cas particulier pour ù/Ù : touche morte circonflexe + w
                    if char in ["ù", "Ù"]:
                        # Envoyer backslash (touche morte ^)
                        to_list.append({"key_code": "backslash"})

                        # Envoyer la touche 'w' du layout Ergopti
                        w_positions = letter_to_num.get("w", [])
                        if w_positions:
                            w_code, w_layer = w_positions[0]
                            w_name = macos_keycodes.get(str(w_code), w_code)
                            w_modifiers: List[str] = []
                            if w_layer == 2:
                                w_modifiers.append("shift")
                            elif w_layer == 5:
                                w_modifiers.append("option")
                            elif w_layer == 6:
                                w_modifiers.extend(["shift", "option"])
                            # Shift logic for ù/Ù
                            if (
                                second_layer == 2
                                or is_trigger_shifted(trigger)
                                or char.isupper()
                            ) and "shift" not in w_modifiers:
                                w_modifiers.append("shift")
                            if w_modifiers:
                                to_list.append(
                                    {
                                        "key_code": w_name,
                                        "modifiers": w_modifiers,
                                    }
                                )
                            else:
                                to_list.append({"key_code": w_name})
                        continue

                    # Multi-key sequence
                    if char_base in multi_sequences:
                        sequences = multi_sequences[char_base]
                        # Use first available sequence
                        sequence = sequences[0]
                        for j, (seq_code, seq_layer) in enumerate(sequence):
                            seq_name = macos_keycodes.get(
                                str(seq_code), seq_code
                            )
                            seq_modifiers: List[str] = []
                            if seq_layer == 2:
                                seq_modifiers.append("shift")
                            elif seq_layer == 5:
                                seq_modifiers.append("option")
                            elif seq_layer == 6:
                                seq_modifiers.extend(
                                    [
                                        "shift",
                                        "option",
                                    ]
                                )
                            # Logique corrigée pour sequences
                            trigger_is_shifted = is_trigger_shifted(trigger)
                            second_is_upper = (
                                second_layer == 2 or second_key.isupper()
                            )

                            if (
                                trigger_is_shifted
                                and second_is_upper
                                and char.isalpha()
                            ):
                                # Trigger shifted ET second_key majuscules -> tout l'output
                                if "shift" not in seq_modifiers:
                                    seq_modifiers.append("shift")
                            elif (
                                trigger_is_shifted or second_is_upper
                            ) and not (trigger_is_shifted and second_is_upper):
                                # Soit trigger OU second_key majuscule -> première lettre seulement
                                if (
                                    i == first_letter_index
                                    and j == 0
                                    and "shift" not in seq_modifiers
                                    and char.isalpha()
                                ):
                                    seq_modifiers.append("shift")

                            if seq_modifiers:
                                to_list.append(
                                    {
                                        "key_code": seq_name,
                                        "modifiers": seq_modifiers,
                                    }
                                )
                            else:
                                to_list.append({"key_code": seq_name})
                        continue

                    # Single key
                    char_positions = letter_to_num.get(char_base, [])
                    if char_positions:
                        char_code, char_layer = char_positions[0]
                        char_name = macos_keycodes.get(
                            str(char_code), char_code
                        )
                    else:
                        char_code, char_layer, char_name = None, None, char_base

                    char_modifiers: List[str] = []
                    if char_layer == 2:
                        char_modifiers.append("shift")
                    elif char_layer == 5:
                        char_modifiers.append("option")
                    elif char_layer == 6:
                        char_modifiers.extend(["shift", "option"])

                    # Logique de casse corrigée:
                    # - Si trigger shifted ET second_key majuscule → tout en majuscules
                    # - Si trigger shifted OU second_key majuscule (mais pas les deux) → première lettre
                    # - Si trigger non-shifted ET second_key minuscule → rien
                    trigger_is_shifted = is_trigger_shifted(trigger)
                    second_is_upper = second_layer == 2 or second_key.isupper()

                    if (
                        trigger_is_shifted
                        and second_is_upper
                        and char.isalpha()
                    ):
                        # Trigger shifted ET second_key majuscules -> tout l'output en majuscule
                        if "shift" not in char_modifiers:
                            char_modifiers.append("shift")
                    elif (trigger_is_shifted or second_is_upper) and not (
                        trigger_is_shifted and second_is_upper
                    ):
                        # Soit trigger OU second_key majuscule (mais pas les deux) -> première lettre seulement
                        if (
                            i == first_letter_index
                            and "shift" not in char_modifiers
                            and char.isalpha()
                        ):
                            char_modifiers.append("shift")

                    if char_modifiers:
                        to_list.append(
                            {"key_code": char_name, "modifiers": char_modifiers}
                        )
                    else:
                        to_list.append({"key_code": char_name})
                # Définir previous_key avec la dernière lettre de l'output
                last_char = output[-1] if output else "none"
                to_list.append(
                    {
                        "set_variable": {
                            "name": "previous_key",
                            "value": "none",  # not last_char, otherwise "ct ?" gives cT’
                        }
                    }
                )
                to_list.append(
                    {
                        "set_variable": {
                            "name": "star_activated",
                            "value": 0,
                        }
                    }
                )

                manipulators.append(
                    {
                        "conditions": [
                            {
                                "name": "previous_key",
                                "type": "variable_if",
                                "value": trigger,
                            }
                        ],
                        "from": from_block,
                        "to": to_list,
                        "type": "basic",
                    }
                )

        # Special case: if previous_key is ê or Ê, send backslash + the pressed key
        # Generate once per trigger, not per second_key/output combination
        # Only for vowels (a, e, i, o, u, y)
        vowels = set("aeiouyAEIOUY")
        for circumflex_char in ["ê", "Ê"]:
            for second_key, output in mapping["map"]:
                # Only process if second_key is a vowel
                if second_key not in vowels:
                    continue

                for second_code, second_layer in letter_to_num.get(
                    second_key.lower(), []
                ):
                    second_name = macos_keycodes.get(
                        str(second_code), second_code
                    )

                    # Layer-based modifiers
                    modifiers = []
                    if second_layer == 2:
                        modifiers.append("shift")
                    elif second_layer == 5:
                        modifiers.append("option")
                    elif second_layer == 6:
                        modifiers.extend(["shift", "option"])
                    if second_key.isupper() and "shift" not in modifiers:
                        modifiers.append("shift")

                    if modifiers:
                        from_block = {
                            "key_code": second_name,
                            "modifiers": {"mandatory": modifiers},
                        }
                    else:
                        from_block = {"key_code": second_name}

                    special_to_list = []
                    special_to_list.append(
                        {
                            "set_variable": {
                                "name": "previous_key",
                                "value": "none",
                            }
                        }
                    )
                    for _ in range(len(circumflex_char)):
                        special_to_list.append(
                            {"key_code": "delete_or_backspace"}
                        )

                    # Send backslash (dead key ^)
                    special_to_list.append({"key_code": "backslash"})

                    # Cas particulier: si second_key est 'e', envoyer 'é' au lieu de 'e'
                    if second_key.lower() == "e":
                        # Trouver la position de 'é' dans le layout Ergopti
                        e_acute_positions = letter_to_num.get("é", [])
                        if e_acute_positions:
                            e_acute_code, e_acute_layer = e_acute_positions[0]
                            e_acute_name = macos_keycodes.get(
                                str(e_acute_code), e_acute_code
                            )
                            e_acute_modifiers: List[str] = []
                            if e_acute_layer == 2:
                                e_acute_modifiers.append("shift")
                            elif e_acute_layer == 5:
                                e_acute_modifiers.append("option")
                            elif e_acute_layer == 6:
                                e_acute_modifiers.extend(["shift", "option"])

                            # Appliquer la casse selon second_key
                            if (
                                second_key.isupper()
                                and "shift" not in e_acute_modifiers
                            ):
                                e_acute_modifiers.append("shift")

                            if e_acute_modifiers:
                                special_to_list.append(
                                    {
                                        "key_code": e_acute_name,
                                        "modifiers": e_acute_modifiers,
                                    }
                                )
                            else:
                                special_to_list.append(
                                    {"key_code": e_acute_name}
                                )
                        else:
                            # Fallback: envoyer e normal si é non trouvé
                            if modifiers:
                                special_to_list.append(
                                    {
                                        "key_code": second_name,
                                        "modifiers": modifiers,
                                    }
                                )
                            else:
                                special_to_list.append(
                                    {"key_code": second_name}
                                )
                    else:
                        # Send the pressed key with its modifiers (cas normal)
                        if modifiers:
                            special_to_list.append(
                                {
                                    "key_code": second_name,
                                    "modifiers": modifiers,
                                }
                            )
                        else:
                            special_to_list.append({"key_code": second_name})

                    # Définir previous_key avec la touche tapée (second_key)
                    special_to_list.append(
                        {
                            "set_variable": {
                                "name": "previous_key",
                                "value": second_key,
                            }
                        }
                    )
                    special_to_list.append(
                        {
                            "set_variable": {
                                "name": "star_activated",
                                "value": 0,
                            }
                        }
                    )

                    manipulators.append(
                        {
                            "conditions": [
                                {
                                    "name": "previous_key",
                                    "type": "variable_if",
                                    "value": circumflex_char,
                                }
                            ],
                            "from": from_block,
                            "to": special_to_list,
                            "type": "basic",
                        }
                    )
    rolls.append(
        {
            "description": f"Roll mapping for trigger '{trigger}' ({mapping_name})",
            "manipulators": manipulators,
        }
    )

# Retardé: on écrira rolls.json après insertion des règles supplémentaires


# Manipulators to update previous_key
letters_manipulators = []
# Multiple symbols may map to the same (keycode, layer)
for (keycode, layer), symbols in num_to_letter.items():
    if keycode > 50:
        continue
    name = macos_keycodes.get(str(keycode), keycode)
    if not name:
        continue
    modifiers = []
    if layer == 2:
        modifiers.append("shift")
    elif layer == 5:
        modifiers.append("option")
    elif layer == 6:
        modifiers.extend(["shift", "option"])
    for symbol in symbols:
        # Special case: keycode 8 [c] with no modifiers sends ★ on j
        if keycode == 8 and not modifiers:
            if REPEAT_KEY:
                letters_manipulators.append(
                    {
                        "type": "basic",
                        "from": {"key_code": name},
                        "to": [
                            {
                                # Use Karabiner's variable substitution to send previous_key
                                "key_code": "__variable__",
                                "set_variable": {
                                    "name": "previous_key",
                                    "value": symbol,
                                },
                            }
                        ],
                    }
                )
            else:
                letters_manipulators.append(
                    {
                        "type": "basic",
                        "from": {"key_code": name},
                        "to": [
                            {
                                "key_code": "close_bracket",
                                "modifiers": ["shift", "option"],
                            },
                            {
                                "set_variable": {
                                    "name": "star_activated",
                                    "value": 1,
                                },
                            },
                        ],
                    }
                )

        elif modifiers:
            letters_manipulators.append(
                {
                    "type": "basic",
                    "from": {
                        "key_code": name,
                        "modifiers": {"mandatory": modifiers},
                    },
                    "to": [
                        {"key_code": name, "modifiers": modifiers},
                        {
                            "set_variable": {
                                "name": "previous_key",
                                "value": symbol.upper()
                                if "shift" in modifiers
                                else symbol,
                            }
                        },
                        {
                            "set_variable": {
                                "name": "star_activated",
                                "value": 0,
                            }
                        },
                    ],
                }
            )
        else:
            letters_manipulators.append(
                {
                    "type": "basic",
                    "from": {"key_code": name},
                    "to": [
                        {"key_code": name},
                        {
                            "set_variable": {
                                "name": "previous_key",
                                "value": symbol,
                            }
                        },
                        {
                            "set_variable": {
                                "name": "star_activated",
                                "value": 0,
                            }
                        },
                    ],
                }
            )
rolls.append(
    {
        "description": "Set previous_key for symbols (all layers, duplicates included)",
        "manipulators": letters_manipulators,
    }
)

# Spécial: si star_activated == 1 et on presse la touche qui produit ê, envoyer 'u'
# sauf si previous_key == 'r' (arrêt), dans ce cas on laisse ê
# On récupère la première position de ê et u (layer 0 ici) et on crée un manipulateur dédié.
try:
    e_positions = letter_to_num.get("ê", [])
    u_positions = letter_to_num.get("u", [])
    if e_positions and u_positions:
        e_keycode, e_layer = e_positions[0]
        u_keycode, u_layer = u_positions[0]
        e_name = macos_keycodes.get(str(e_keycode), e_keycode)
        u_name = macos_keycodes.get(str(u_keycode), u_keycode)
        e_mods: List[str] = []
        if e_layer == 2:
            e_mods.append("shift")
        elif e_layer == 5:
            e_mods.append("option")
        elif e_layer == 6:
            e_mods.extend(["shift", "option"])
        u_mods: List[str] = []
        if u_layer == 2:
            u_mods.append("shift")
        elif u_layer == 5:
            u_mods.append("option")
        elif u_layer == 6:
            u_mods.extend(["shift", "option"])
        from_block: dict = {"key_code": e_name}
        if e_mods:
            from_block["modifiers"] = {"mandatory": e_mods}
        to_event: dict = {"key_code": u_name}
        if u_mods:
            to_event["modifiers"] = u_mods

        # Cas 1: star_activated == 1 ET previous_key != 'r' ET previous_key != 'n' => ê devient u
        rolls.append(
            {
                "description": "Special mapping: star_activated + ê => u (except after r or n)",
                "manipulators": [
                    {
                        "type": "basic",
                        "from": from_block,
                        "conditions": [
                            {
                                "type": "variable_if",
                                "name": "star_activated",
                                "value": 1,
                            },
                            {
                                "type": "variable_unless",
                                "name": "previous_key",
                                "value": "r",
                            },
                            {
                                "type": "variable_unless",
                                "name": "previous_key",
                                "value": "n",
                            },
                        ],
                        "to": [
                            to_event,
                            {
                                "set_variable": {
                                    "name": "star_activated",
                                    "value": 0,
                                }
                            },
                            {
                                "set_variable": {
                                    "name": "previous_key",
                                    "value": "u",
                                }
                            },
                        ],
                    }
                ],
            }
        )

        # Cas 2: star_activated == 1 ET previous_key == 'r' => ê reste ê (arrêt)
        rolls.append(
            {
                "description": "Special mapping: star_activated + r + ê => ê (stop)",
                "manipulators": [
                    {
                        "type": "basic",
                        "from": from_block,
                        "conditions": [
                            {
                                "type": "variable_if",
                                "name": "star_activated",
                                "value": 1,
                            },
                            {
                                "type": "variable_if",
                                "name": "previous_key",
                                "value": "r",
                            },
                        ],
                        "to": [
                            {"key_code": e_name}
                            if not e_mods
                            else {"key_code": e_name, "modifiers": e_mods},
                            {
                                "set_variable": {
                                    "name": "star_activated",
                                    "value": 0,
                                }
                            },
                            {
                                "set_variable": {
                                    "name": "previous_key",
                                    "value": "ê",
                                }
                            },
                        ],
                    }
                ],
            }
        )

        # Cas 3: star_activated == 1 ET previous_key == 'n' => ê reste ê (honnête)
        rolls.append(
            {
                "description": "Special mapping: star_activated + n + ê => ê (honnête)",
                "manipulators": [
                    {
                        "type": "basic",
                        "from": from_block,
                        "conditions": [
                            {
                                "type": "variable_if",
                                "name": "star_activated",
                                "value": 1,
                            },
                            {
                                "type": "variable_if",
                                "name": "previous_key",
                                "value": "n",
                            },
                        ],
                        "to": [
                            {"key_code": e_name}
                            if not e_mods
                            else {"key_code": e_name, "modifiers": e_mods},
                            {
                                "set_variable": {
                                    "name": "star_activated",
                                    "value": 0,
                                }
                            },
                            {
                                "set_variable": {
                                    "name": "previous_key",
                                    "value": "ê",
                                }
                            },
                        ],
                    }
                ],
            }
        )
except Exception:  # Défensif: ne pas casser la génération
    pass


def build_previous_key_repeat_manipulators(trigger_key: str) -> list:
    """Return manipulators that replay previous_key when trigger_key is pressed.

    For each possible symbol stored in previous_key (derived from macOS keycodes
    0-50), find its Ergopti physical key (first occurrence in letter_to_num) and
    send that key with proper layer-based modifiers.
    """
    manips: List[dict] = []
    for keycode_id in range(0, 51):
        prev_symbol = macos_keycodes.get(str(keycode_id))
        if not prev_symbol:
            continue
        # Lookup Ergopti position(s) for this symbol
        positions = letter_to_num.get(prev_symbol, [])
        if not positions:
            continue
        erg_keycode, erg_layer = positions[0]
        erg_key_name = macos_keycodes.get(str(erg_keycode), erg_keycode)
        mods: List[str] = []
        if erg_layer == 2:
            mods.append("shift")
        elif erg_layer == 5:
            mods.append("option")
        elif erg_layer == 6:
            mods.extend(["shift", "option"])
        to_event: dict = {"key_code": erg_key_name}
        if mods:
            to_event["modifiers"] = mods
        manips.append(
            {
                "type": "basic",
                "from": {
                    "key_code": trigger_key,
                    "modifiers": {"optional": ["any"]},
                },
                "conditions": [
                    {
                        "type": "variable_if",
                        "name": "previous_key",
                        "value": prev_symbol,
                    }
                ],
                "to": [to_event],
            }
        )
    return manips


if REPEAT_KEY:
    # Replay previous character with 'v' (keycode 9 / .j on Ergopti) and '8'
    repeat_v = build_previous_key_repeat_manipulators("c")
    repeat_8 = build_previous_key_repeat_manipulators("8")
    rolls.append(
        {
            "description": "Replay previous_key with v (.j)",
            "manipulators": repeat_v,
        }
    )
    rolls.append(
        {
            "description": "Replay previous_key with 8",  # top-row 8 used as repeat
            "manipulators": repeat_8,
        }
    )

# Écriture finale de rolls.json avec toutes les règles (y compris spéciales et repeat)
with open(output_path, "w", encoding="utf-8") as f:
    json.dump(rolls, f, ensure_ascii=False, indent=2)

# Group manipulators by physical key into rolls_grouped.json
rolls_grouped_path = Path(__file__).parent / "rolls_grouped.json"
manipulators_by_key = {}
for rule in rolls:
    for manip in rule["manipulators"]:
        key_code = manip.get("from", {}).get("key_code")
        # Use string key_code for grouping
        if isinstance(key_code, dict):
            # Defensive conversion if dict appears (should not happen)
            key = str(key_code)
        else:
            key = key_code
        if key not in manipulators_by_key:
            manipulators_by_key[key] = []
        manipulators_by_key[key].append(manip)

grouped = []


for key, manips in manipulators_by_key.items():
    desc = f"Grouped actions for key [{key}]"

    # Sort priority: shift+option, option, shift, none
    def mod_priority(manip):
        from_block = manip.get("from", {})
        mods = from_block.get("modifiers", {})
        if isinstance(mods, dict):
            mandatory = mods.get("mandatory", [])
            # Peut être une chaîne ou une liste
            if isinstance(mandatory, str):
                mandatory = [mandatory]
            if "shift" in mandatory and "option" in mandatory:
                return 0
            elif "option" in mandatory:
                return 1
            elif "shift" in mandatory:
                return 2
        return 3

    sorted_manips = sorted(
        manips,
        key=mod_priority,
    )
    # Priorisation spécifique: pour la touche grave_accent_and_tilde, placer
    # les manipulateurs avec condition star_activated == 1 avant ceux sans conditions
    if key == "grave_accent_and_tilde":
        special = []
        others = []
        for m in sorted_manips:
            conds = m.get("conditions", [])
            if any(
                c.get("name") == "star_activated" and c.get("value") == 1
                for c in conds
            ):
                special.append(m)
            else:
                others.append(m)
        sorted_manips = special + others
    grouped.append(
        {
            "description": desc,
            "manipulators": sorted_manips,
        }
    )

with open(rolls_grouped_path, "w", encoding="utf-8") as f:
    json.dump(grouped, f, ensure_ascii=False, indent=2)


def merge_rolls_into_karabiner(
    karabiner_path: str, rolls_path: str, output_path: str
) -> None:
    """Merge rolls.json rules into karabiner0.json and write to karabiner.json.

    Args:
        karabiner_path: Path to the base Karabiner JSON file.
        rolls_path: Path to the generated rolls JSON file.
        output_path: Path to write the merged Karabiner JSON file.

    Raises:
        FileNotFoundError: If any input file is missing.
        ValueError: If the JSON structure is invalid.
    """
    with open(karabiner_path, "r", encoding="utf-8") as f:
        karabiner_data: dict = json.load(f)

    with open(rolls_path, "r", encoding="utf-8") as f:
        rolls_data: list = json.load(f)

    try:
        rules: list = karabiner_data["profiles"][0]["complex_modifications"][
            "rules"
        ]
        for roll in rolls_data:
            rules.append(roll)
    except (KeyError, IndexError) as exc:
        raise ValueError("Invalid Karabiner or rolls JSON structure") from exc

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(karabiner_data, f, indent=4, ensure_ascii=False)


if __name__ == "__main__":
    base_dir = Path(__file__).parent

    merge_rolls_into_karabiner(
        karabiner_path=str(base_dir / "data" / "karabiner0.json"),
        rolls_path=str(base_dir / "rolls_grouped.json"),
        output_path=str(base_dir / "karabiner.json"),
    )
