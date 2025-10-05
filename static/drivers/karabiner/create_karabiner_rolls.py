import json
import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent.parent))
from macos.keylayout_generation.data.keylayout_plus_mappings import (
    PLUS_MAPPINGS_CONFIG,
)

output_path = Path(__file__).parent / "rolls.json"
rolls = []

for mapping_name, mapping in PLUS_MAPPINGS_CONFIG.items():
    trigger = mapping["trigger"]
    manipulators = []

    # 1. When trigger is pressed, activate the variable
    manipulators.append(
        {
            "from": {"key_code": trigger},
            "to": [
                {"key_code": trigger},
                {
                    "set_variable": {
                        "name": f"roll_{trigger}_pressed",
                        "value": 1,
                    }
                },
            ],
            "to_after_key_up": [
                {
                    "set_variable": {
                        "name": f"roll_{trigger}_pressed",
                        "value": 0,
                    }
                }
            ],
            "type": "basic",
        }
    )

    # 2. For each (second_key, output) pair
    for second_key, output in mapping["map"]:
        # If variable is active, send output
        manipulators.append(
            {
                "conditions": [
                    {
                        "name": f"roll_{trigger}_pressed",
                        "type": "variable_if",
                        "value": 1,
                    }
                ],
                "from": {"key_code": second_key},
                "to": [{"key_code": output}],
                "type": "basic",
            }
        )
        # Otherwise, send the normal key
        manipulators.append(
            {
                "conditions": [
                    {
                        "name": f"roll_{trigger}_pressed",
                        "type": "variable_unless",
                        "value": 1,
                    }
                ],
                "from": {"key_code": second_key},
                "to": [{"key_code": second_key}],
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
