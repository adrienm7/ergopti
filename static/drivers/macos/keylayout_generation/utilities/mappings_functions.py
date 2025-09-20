import re


def add_case_sensitive_mappings(mappings: dict) -> dict:
    """
    Generate mappings for all trigger/key case combinations.
    Special handling for triggers like ',' to produce multiple uppercase variants.
    Applies correct output capitalisation depending on trigger/key case.
    - Trigger uppercase + key uppercase -> output uppercase
    - Trigger uppercase + key lowercase -> output titlecase
    - Trigger lowercase + key uppercase -> output titlecase
    - Trigger lowercase + key lowercase -> output as is
    Avoids duplicates if lower=upper (e.g., ★).
    """
    # First, ensure all original mappings have both lower/upper key variants
    new_mappings = {}
    for key, data in mappings.items():
        if not data.get("map"):
            new_mappings[key] = data.copy()
            continue
        # Replace the map with all key variants (lower/upper)
        new_mappings[key] = {
            "trigger": data["trigger"],
            "map": build_case_map(data["map"], is_trigger_upper=False),
        }

    used_triggers = set()
    for data in new_mappings.values():
        used_triggers.add(data["trigger"])
    for key, data in mappings.items():
        if not data.get("map"):
            continue
        process_mapping(new_mappings, key, data, used_triggers)
    return new_mappings


def process_mapping(
    new_mappings: dict, key: str, data: dict, used_triggers: set
):
    """Process a single mapping entry and add all case-sensitive variants, avoiding duplicate triggers."""
    trigger = data["trigger"]
    trigger_variants = get_trigger_variants(trigger)
    for trigger_val, is_trigger_upper in trigger_variants:
        special_upper_triggers = {",": [";", " ;", ":", " :"], "'": ["?", " ?"]}
        if is_trigger_upper and trigger_val in special_upper_triggers:
            triggers_to_add = special_upper_triggers[trigger_val]
        else:
            triggers_to_add = [trigger_val]

        uppercase_count = 1
        for actual_trigger in triggers_to_add:
            if actual_trigger in used_triggers:
                continue  # Skip duplicate trigger
            used_triggers.add(actual_trigger)
            # Use _uppercase for uppercase triggers, else _map
            if is_trigger_upper or (trigger_val != actual_trigger):
                if len(triggers_to_add) > 1:
                    # If multiple uppercase variants, add _2, _3, ...
                    suffix = (
                        f"_{uppercase_count}" if uppercase_count > 1 else ""
                    )
                    new_key_name = f"{key}_uppercase{suffix}"
                    uppercase_count += 1
                else:
                    new_key_name = f"{key}_uppercase"
            else:
                new_key_name = f"{key}_map"
            new_map = build_case_map(data["map"], is_trigger_upper)
            new_mappings[new_key_name] = {
                "trigger": actual_trigger,
                "map": new_map,
            }


def get_trigger_variants(trigger: str) -> list[tuple[str, bool]]:
    """Return trigger variants: lowercase and uppercase."""
    return [(trigger, False), (trigger.upper(), True)]


def build_case_map(
    mapping: list[tuple[str, str]], is_trigger_upper: bool
) -> list[tuple[str, str]]:
    """
    Generate all key case combinations for a given trigger case.
    Applies output capitalisation rules.
    """
    new_map = []
    for key_char, value in mapping:
        # Always add both lowercase and uppercase variants
        key_lower = key_char.lower()
        key_upper = key_char.upper()
        out_lower = get_output_for_case(is_trigger_upper, False, value)
        out_upper = get_output_for_case(is_trigger_upper, True, value)
        new_map.append((key_lower, out_lower))
        if key_upper != key_lower:
            new_map.append((key_upper, out_upper))
    return new_map


def get_output_for_case(
    trigger_upper: bool, key_upper: bool, value: str
) -> str:
    """
    Determine the output based on the case of trigger and key:
    - Lower + lower -> original
    - Lower + upper -> titlecase
    - Upper + lower -> titlecase
    - Upper + upper -> uppercase
    """
    if trigger_upper and key_upper:
        return value.upper()
    elif trigger_upper or key_upper:
        return value.title()
    else:
        return value


def escape_symbols_in_mappings(mappings: dict) -> dict:
    """
    Go through all mappings and replace XML-breaking characters in the triggers and outputs.
    """
    new_mappings = {}
    for feature, data in mappings.items():
        feature = escape_xml_characters(feature)
        trigger = escape_xml_characters(data["trigger"])

        if not data["map"]:
            new_mappings[feature] = {"trigger": trigger, "map": []}
            continue

        fixed_map = []
        for character, output in data["map"]:
            fixed_map.append(
                (
                    escape_xml_characters(character),
                    escape_xml_characters(output),
                )
            )

        new_mappings[feature] = {
            "trigger": trigger,
            "map": fixed_map,
        }

    return new_mappings


def escape_xml_characters(value: str) -> str:
    """
    Escape &, <, >, " and ' in the given string for XML.
    Already-escaped sequences like &#xNNNN; are preserved.
    """
    if not value:
        return value

    # Regex to detect numeric XML entities like &#x0026;
    numeric_entity_pattern = re.compile(r"&#x[0-9A-Fa-f]+;")

    # Split by numeric entities, escape only non-entities
    parts = numeric_entity_pattern.split(value)
    entities = numeric_entity_pattern.findall(value)

    escaped_parts = [
        part.replace("&", "&#x0026;")
        .replace("<", "&#x003C;")
        .replace(">", "&#x003E;")
        .replace('"', "&#x0022;")
        .replace("'", "&#x0027;")
        for part in parts
    ]

    # Reconstruct while preserving original entities
    result = "".join(
        p + (e if i < len(entities) else "")
        for i, (p, e) in enumerate(zip(escaped_parts, entities + [""]))
    )

    return result
