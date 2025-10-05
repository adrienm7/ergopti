import json
import re
import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent.parent))
from macos.keylayout_generation.data.keylayout_plus_mappings import (
    PLUS_MAPPINGS_CONFIG,
)


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


keylayout_path = str(
    Path(__file__).parent.parent / "macos" / "Ergopti_v2.2.0.keylayout"
)
keycode_map = get_keycode_map(keylayout_path)


PLUS_MAPPINGS_CONFIG = {
    "roll_ck": {
        "trigger": "c",
        "map": [
            ("x", "ck"),
        ],
    },
    "roll_wh": {
        "trigger": "h",
        "map": [
            ("c", "wh"),
        ],
    },
    "roll_sk": {
        "trigger": "s",
        "map": [
            ("x", "sk"),
        ],
    },
}
output_path = Path(__file__).parent / "rolls.json"
rolls = []


with open(
    str(Path(__file__).parent / "macos_keycodes.json"), encoding="utf-8"
) as f:
    macos_keycodes = json.load(f)

output_path = Path(__file__).parent / "rolls.json"
rolls = []

for mapping_name, mapping in PLUS_MAPPINGS_CONFIG.items():
    trigger = mapping["trigger"]
    trigger_code = keycode_map.get(trigger)
    trigger_name = keycode_to_name(trigger_code, macos_keycodes)
    manipulators = []

    # 1. When trigger is pressed, activate the variable
    manipulators.append(
        {
            "from": {"key_code": trigger_name},
            "to": [
                {"key_code": trigger_name},
                {"set_variable": {"name": f"{trigger}_pressed", "value": 1}},
            ],
            "to_after_key_up": [
                {"set_variable": {"name": f"{trigger}_pressed", "value": 0}},
            ],
            "type": "basic",
        }
    )

    # 2. For each (second_key, output) pair
    for second_key, output in mapping["map"]:
        second_code = keycode_map.get(second_key)
        output_code = keycode_map.get(output)
        second_name = keycode_to_name(second_code, macos_keycodes)
        output_name = keycode_to_name(output_code, macos_keycodes)
        manipulators.append(
            {
                "conditions": [
                    {
                        "name": f"{trigger}_pressed",
                        "type": "variable_if",
                        "value": 1,
                    },
                ],
                "from": {"key_code": second_name},
                "to": [{"key_code": output_name}],
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
    merge_rolls_into_karabiner(
        karabiner_path="d:/Documents/GitHub/ergopti/static/drivers/karabiner/karabiner0.json",
        rolls_path="d:/Documents/GitHub/ergopti/static/drivers/karabiner/rolls.json",
        output_path="d:/Documents/GitHub/ergopti/static/drivers/karabiner/karabiner.json",
    )
