import json
import re
import sys
from pathlib import Path

PLUS_MAPPINGS_CONFIG = {
    "roll_wh": {
        "trigger": "h",
        "map": [
            ("c", "wh"),
        ],
    },
}

sys.path.append(str(Path(__file__).parent.parent.resolve()))
from macos.keylayout_generation.data.keylayout_plus_mappings import (
    PLUS_MAPPINGS_CONFIG,
    add_case_sensitive_mappings,
)

plus_mappings = add_case_sensitive_mappings(PLUS_MAPPINGS_CONFIG)


def keycode_to_name(code, macos_keycodes):
    if code is None:
        return None
    return macos_keycodes.get(str(code), code)


def get_keycode_map(keylayout_path: str) -> dict:
    keycode_map = {}
    with open(keylayout_path, encoding="utf-8") as f:
        content = f.read()
        keymap_match = re.search(
            r'<keyMap index="0">(.*?)</keyMap>', content, re.DOTALL
        )
        if not keymap_match:
            return keycode_map
        keymap_content = keymap_match.group(1)
        for m in re.finditer(
            r'<key code="(\d+)"(?: action="([^"]+)")?(?: output="([^"]+)")?/?',
            keymap_content,
        ):
            code = int(m.group(1))
            action = m.group(2)
            output = m.group(3)
            if action:
                keycode_map[action] = code
            elif output and not re.match(r"^&#x[0-9A-Fa-f]+;$", output):
                keycode_map[output] = code
    return keycode_map


keylayout_path = (
    Path(__file__).parent.parent / "macos" / "Ergopti_v2.2.0.keylayout"
)
keycode_map = get_keycode_map(str(keylayout_path))
num_to_letter = {v: k for k, v in keycode_map.items()}


output_path = Path(__file__).parent / "rolls.json"
rolls = []

with open(Path(__file__).parent / "macos_keycodes.json", encoding="utf-8") as f:
    macos_keycodes = json.load(f)

for mapping_name, mapping in plus_mappings.items():
    trigger = mapping["trigger"]
    trigger_code = keycode_map.get(trigger.lower())
    trigger_name = keycode_to_name(trigger_code, macos_keycodes)

    manipulators = []

    # 2. For each (second_key, output) pair
    for second_key, output in mapping["map"]:
        second_code = keycode_map.get(second_key.lower())
        second_name = keycode_to_name(second_code, macos_keycodes)

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

        if second_key.isupper():
            from_block = {
                "key_code": second_name,
                "modifiers": {"mandatory": ["shift"]},
            }
        else:
            from_block = {"key_code": second_name}

        for i, char in enumerate(output):
            char_base = char.lower()
            char_code = keycode_map.get(char_base)
            char_name = keycode_to_name(char_code, macos_keycodes)
            char_name = char_name or char_base
            if trigger.isupper() and second_key.isupper():
                to_list.append({"key_code": char_name, "modifiers": "shift"})
            elif i == 0 and (trigger.isupper() or second_key.isupper()):
                to_list.append({"key_code": char_name, "modifiers": "shift"})
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
for keycode, name in macos_keycodes.items():
    trigger_name = keycode

    trigger_name = str(num_to_letter.get(int(keycode)))

    letters_manipulators.append(
        {
            "from": {
                "key_code": name,
                "modifiers": {"mandatory": ["shift"]},
            },
            "to": [
                {"key_code": name, "modifiers": ["shift"]},
                {
                    "set_variable": {
                        "name": "previous_key",
                        "value": trigger_name.upper(),
                    }
                },
            ],
            "type": "basic",
        }
    )
    letters_manipulators.append(
        {
            "from": {"key_code": name},
            "to": [
                {"key_code": name},
                {
                    "set_variable": {
                        "name": "previous_key",
                        "value": trigger_name,
                    }
                },
            ],
            "type": "basic",
        }
    )
rolls.append(
    {
        "description": "Set previous_key for a-z",
        "manipulators": letters_manipulators,
    }
)

# Regroupement des manipulateurs par touche dans rolls_grouped.json
rolls_grouped_path = Path(__file__).parent / "rolls_grouped.json"
manipulators_by_key = {}
for rule in rolls:
    for manip in rule["manipulators"]:
        key = manip["from"].get("key_code")
        if key not in manipulators_by_key:
            manipulators_by_key[key] = []
        manipulators_by_key[key].append(manip)

grouped = []


for key, manips in manipulators_by_key.items():
    desc = f"Actions regroupées pour la touche [{key}]"

    # Tri explicite des manipulateurs : les plus spécifiques (shift dans 'from') en premier
    def has_shift_from(manip):
        from_block = manip.get("from", {})
        mods = from_block.get("modifiers", {})
        if isinstance(mods, dict):
            return "shift" in str(mods.get("mandatory", []))
        return False

    sorted_manips = sorted(
        manips,
        key=lambda m: not has_shift_from(m),
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

    print(keycode_map)
    print(num_to_letter)

    merge_rolls_into_karabiner(
        karabiner_path=str(base_dir / "karabiner0.json"),
        rolls_path=str(base_dir / "rolls_grouped.json"),
        output_path=str(base_dir / "karabiner.json"),
    )
