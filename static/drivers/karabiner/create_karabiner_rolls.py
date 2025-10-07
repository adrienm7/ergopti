import json
import re
import sys
from collections import defaultdict
from pathlib import Path

PLUS_MAPPINGS_CONFIG = {
    "roll_wh": {
        "trigger": "h",
        "map": [
            ("c", "wh"),
        ],
    },
    "rolls_question_mark": {
        "trigger": "?",
        "map": [
            ("+", " <- "),
        ],
    },
}

sys.path.append(str(Path(__file__).parent.parent.resolve()))
from macos.keylayout_generation.data.keylayout_plus_mappings import (
    # PLUS_MAPPINGS_CONFIG,
    add_case_sensitive_mappings,
)
from macos.keylayout_generation.data.mappings_functions import (
    unescape_xml_characters,
)
from utilities.keylayout_extraction import extract_keymap_body

plus_mappings = add_case_sensitive_mappings(PLUS_MAPPINGS_CONFIG)


def get_keycode_map(keylayout_path: str) -> dict[str, list[dict[str, int]]]:
    keycode_map = defaultdict(list)
    with open(keylayout_path, encoding="utf-8") as f:
        content = f.read()
        # On ne prend que les couches utiles
        for layer_index in [0, 2, 5, 6]:
            keymap_content = extract_keymap_body(content, layer_index)
            for m in re.finditer(
                r'<key code="(\d+)" (action|output)="([^"]+)"',
                keymap_content,
            ):
                code = int(m.group(1))
                if code > 50:
                    continue
                output = m.group(3)
                if output:
                    keycode_map[output].append(
                        {
                            "keycode": code,
                            "layer": layer_index,
                        }
                    )
    return dict(keycode_map)


keylayout_path = (
    Path(__file__).parent.parent / "macos" / "Ergopti_v2.2.0.keylayout"
)
keycode_map = get_keycode_map(str(keylayout_path))

keycode_map = {unescape_xml_characters(k): v for k, v in keycode_map.items()}

letter_to_num = defaultdict(list)
num_to_letter = defaultdict(list)
for k, positions in keycode_map.items():
    for pos in positions:
        letter_to_num[k].append((pos["keycode"], pos["layer"]))
        num_to_letter[(pos["keycode"], pos["layer"])].append(k)


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
        # 2. For each (second_key, output) pair
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

                # Détermine les modificateurs selon la couche de second_key
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

                for i, char in enumerate(output):
                    char_base = char.lower()
                    char_positions = letter_to_num.get(char_base, [])
                    if char_positions:
                        char_code, char_layer = char_positions[0]
                        char_name = macos_keycodes.get(
                            str(char_code), char_code
                        )
                    else:
                        char_code, char_layer, char_name = None, None, char_base

                    char_modifiers = []
                    if char_layer == 2:
                        char_modifiers.append("shift")
                    elif char_layer == 5:
                        char_modifiers.append("option")
                    elif char_layer == 6:
                        char_modifiers.extend(["shift", "option"])

                    # Si trigger ET second_key sont en majuscule, tout l'output doit être shifté
                    if trigger.isupper() and second_key.isupper():
                        if "shift" not in char_modifiers:
                            char_modifiers.append("shift")
                    # Sinon, pour le premier caractère, on ajoute shift si trigger OU second_key est majuscule
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


# Ajoute un manipulateur pour chaque lettre a-z qui met à jour previous_key
letters_manipulators = []
# Pour chaque (keycode, layer), on peut avoir plusieurs symboles
for (keycode, layer), symbols in num_to_letter.items():
    if keycode > 50:
        continue
    name = macos_keycodes.get(str(keycode), keycode)
    if not name:
        continue
    # Détermine les modificateurs selon la couche
    modifiers = []
    if layer == 2:
        modifiers.append("shift")
    elif layer == 5:
        modifiers.append("option")
    elif layer == 6:
        modifiers.extend(["shift", "option"])
    for symbol in symbols:
        if modifiers:
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
        "description": "Set previous_key for a-z (toutes couches, doublons inclus)",
        "manipulators": letters_manipulators,
    }
)

# Regroupement des manipulateurs par touche dans rolls_grouped.json
rolls_grouped_path = Path(__file__).parent / "rolls_grouped.json"
manipulators_by_key = {}
for rule in rolls:
    for manip in rule["manipulators"]:
        key_code = manip.get("from", {}).get("key_code")
        # Utilise la chaîne key_code comme clé, ignore les dicts
        if isinstance(key_code, dict):
            # Si key_code est un dict (jamais le cas normalement), le convertir en str
            key = str(key_code)
        else:
            key = key_code
        if key not in manipulators_by_key:
            manipulators_by_key[key] = []
        manipulators_by_key[key].append(manip)

grouped = []


for key, manips in manipulators_by_key.items():
    desc = f"Actions regroupées pour la touche [{key}]"

    # Tri explicite des manipulateurs :
    # 1. shift+option
    # 2. option
    # 3. shift
    # 4. aucun modificateur
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
