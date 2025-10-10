"""Generate Karabiner roll rules for Ergopti(+).

Extract key positions from the macOS .keylayout file, build roll / dead-key
manipulators based on the Ergopti+ mapping configuration, and export:
    - rolls.json: raw list of rules grouped by trigger mapping
    - rolls_grouped.json: rules regrouped by originating key
    - karabiner.json: merged configuration (by adding those rules to base file)

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
from utilities.keylayout_plus_mappings import (
    PLUS_MAPPINGS_CONFIG,
    add_case_sensitive_mappings,
)
from utilities.mappings_functions import (
    unescape_xml_characters,
)

REPEAT_KEY = False
plus_mappings = add_case_sensitive_mappings(PLUS_MAPPINGS_CONFIG)


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


keylayout_path = (
    Path(__file__).parent.parent / "macos" / "Ergopti_v2.2.0.keylayout"
)
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
                to_list.append({"key_code": "delete_or_backspace"})

                # Layer-based modifiers
                modifiers = []
                if second_layer == 2:
                    modifiers.append("shift")
                elif second_layer == 5:
                    modifiers.append("right_option")
                elif second_layer == 6:
                    modifiers.extend(["shift", "right_option"])
                if second_key.isupper() and "shift" not in modifiers:
                    modifiers.append("shift")

                if modifiers:
                    from_block = {
                        "key_code": second_name,
                        "modifiers": {"mandatory": modifiers},
                    }
                else:
                    from_block = {"key_code": second_name}

                for i, char in enumerate(output):
                    char_base = char.lower()

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
                                seq_modifiers.append("right_option")
                            elif seq_layer == 6:
                                seq_modifiers.extend(
                                    [
                                        "shift",
                                        "right_option",
                                    ]
                                )
                            # Apply shift to first key of sequence if needed
                            if (
                                (trigger.isupper() and second_key.isupper())
                                or (
                                    (trigger.isupper() or second_key.isupper())
                                    and i == 0
                                    and j == 0
                                )
                            ) and "shift" not in seq_modifiers:
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
                        char_modifiers.append("right_option")
                    elif char_layer == 6:
                        char_modifiers.extend(["shift", "right_option"])

                    # Shift entire output if both keys uppercase
                    if trigger.isupper() and second_key.isupper():
                        if "shift" not in char_modifiers:
                            char_modifiers.append("shift")
                    # Else add shift only to first char if one is uppercase
                    elif (
                        i == 0
                        and (trigger.isupper() or second_key.isupper())
                        and "shift" not in char_modifiers
                    ):
                        char_modifiers.append("shift")

                    if char_modifiers:
                        to_list.append(
                            {"key_code": char_name, "modifiers": char_modifiers}
                        )
                    else:
                        to_list.append({"key_code": char_name})

                to_list.append(
                    {
                        "set_variable": {
                            "name": "previous_key",
                            "value": "none",
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
    rolls.append(
        {
            "description": f"Roll mapping for trigger '{trigger}' ({mapping_name})",
            "manipulators": manipulators,
        }
    )

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(rolls, f, ensure_ascii=False, indent=2)


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
        modifiers.append("right_option")
    elif layer == 6:
        modifiers.extend(["shift", "right_option"])
    for symbol in symbols:
        # Special case: keycode 8 (c) with no modifiers sends previous_key
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
                            {"key_code": "backslash"},
                            {"key_code": "m"},
                            {
                                "set_variable": {
                                    "name": "previous_key",
                                    "value": "★",
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
                    ],
                }
            )
rolls.append(
    {
        "description": "Set previous_key for symbols (all layers, duplicates included)",
        "manipulators": letters_manipulators,
    }
)


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
            mods.append("right_option")
        elif erg_layer == 6:
            mods.extend(["shift", "right_option"])
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
            if "shift" in mandatory and "right_option" in mandatory:
                return 0
            elif "right_option" in mandatory:
                return 1
            elif "shift" in mandatory:
                return 2
        return 3

    sorted_manips = sorted(
        manips,
        key=mod_priority,
    )
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
