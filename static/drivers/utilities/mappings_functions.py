"""
Utility functions for processing key mappings:
- Add case sensitivity
- Escape XML characters
- Unescape XML characters
- Validate uniqueness of triggers
- Generate case variants for trigger-replacement pairs
"""

import re
from typing import List, Tuple

# Table de remplacement XML <-> caractères normaux
XML_ESCAPE_TABLE = {
    "&": "&#x0026;",
    "<": "&#x003C;",
    ">": "&#x003E;",
    '"': "&#x0022;",
    "'": "&#x0027;",
}
XML_UNESCAPE_TABLE = {v: k for k, v in XML_ESCAPE_TABLE.items()}

# Special character mappings for "uppercase" equivalents
SPECIAL_UPPERCASE_CHARS = {
    "'": "\u202f?",  # apostrophe -> espace insécable + question mark
    ",": "\u202f;",  # comma -> espace insécable + semicolon
}


def get_special_uppercase_variants(char: str) -> List[str]:
    """
    Get special uppercase variants for characters that don't have standard uppercase.

    Args:
        char: The character to get variants for

    Returns:
        List of special uppercase variants (only one variant per character)
    """
    if char in SPECIAL_UPPERCASE_CHARS:
        return [SPECIAL_UPPERCASE_CHARS[char]]
    return []


def generate_mixed_case_variants(trigger: str) -> List[str]:
    """
    Generate mixed case variants like aB, Ab, AB for multi-character triggers.

    Args:
        trigger: The original trigger

    Returns:
        List of mixed case trigger variants
    """
    if len(trigger) < 2:
        return []

    variants = []
    # For 2-character triggers, generate: aB, Ab, AB
    if len(trigger) == 2:
        a, b = trigger[0], trigger[1]
        # aB (first lower, second upper)
        if a.lower() != a.upper() and b.lower() != b.upper():
            mixed1 = a.lower() + b.upper()
            if mixed1 not in [
                trigger.lower(),
                trigger.upper(),
                trigger.capitalize(),
            ] and b not in [" ?", " ;", " :"]:
                # We remove ' ?' to avoid 'stp ?' giving 'stCt'
                variants.append(mixed1)

    return variants


def generate_case_variants_for_trigger_replacement(
    trigger: str, replacement: str
) -> List[Tuple[str, str]]:
    """
    Generate case variants for a trigger-replacement pair.
    Follows the same logic as Alfred snippets generation:
    - Lowercase trigger -> lowercase replacement
    - Title case trigger -> title case replacement
    - Uppercase trigger -> uppercase replacement (only for multi-character triggers)
    - Mixed case triggers like aB -> Mixed case outputs like Cd
    - Special character mappings like ' -> ? and , -> ;

    Special rule: if uppercase trigger equals title case trigger (e.g., single char),
    only generate one entry with title case output.

    Args:
        trigger: Original trigger
        replacement: Original replacement text

    Returns:
        List of (trigger, replacement) tuples with different case variants (no duplicates)
    """
    variants = []
    seen_triggers = set()

    # Original (lowercase)
    lower_trigger = trigger.lower()
    lower_replacement = replacement.lower()
    if lower_trigger not in seen_triggers:
        variants.append((lower_trigger, lower_replacement))
        seen_triggers.add(lower_trigger)

    # Title case (first letter uppercase)
    if len(trigger) > 0:
        title_trigger = trigger.capitalize()
        upper_trigger = trigger.upper()

        # Check if title case and uppercase are the same
        if title_trigger == upper_trigger:
            # For single character or cases where title == upper, use title case output
            title_replacement = apply_case_to_replacement_text(
                title_trigger, replacement
            )
            if title_trigger not in seen_triggers:
                variants.append((title_trigger, title_replacement))
                seen_triggers.add(title_trigger)
        else:
            # Generate both title and uppercase variants
            title_replacement = apply_case_to_replacement_text(
                title_trigger, replacement
            )
            if title_trigger not in seen_triggers:
                variants.append((title_trigger, title_replacement))
                seen_triggers.add(title_trigger)

            # Uppercase (only for multi-character triggers where upper != title)
            if len(trigger) > 1:
                upper_replacement = apply_case_to_replacement_text(
                    upper_trigger, replacement
                )
                if upper_trigger not in seen_triggers:
                    variants.append((upper_trigger, upper_replacement))
                    seen_triggers.add(upper_trigger)

    # Generate mixed case variants (aB -> Cd)
    mixed_variants = generate_mixed_case_variants(trigger)
    for mixed_trigger in mixed_variants:
        if mixed_trigger not in seen_triggers:
            mixed_replacement = apply_mixed_case_to_replacement(
                mixed_trigger, replacement
            )
            variants.append((mixed_trigger, mixed_replacement))
            seen_triggers.add(mixed_trigger)

    # Generate special character variants for all existing variants
    existing_variants = variants.copy()
    for variant_trigger, variant_replacement in existing_variants:
        for i, char in enumerate(variant_trigger):
            special_variants = get_special_uppercase_variants(char)
            for special_char in special_variants:
                special_trigger = (
                    variant_trigger[:i]
                    + special_char
                    + variant_trigger[i + 1 :]
                )
                if special_trigger not in seen_triggers:
                    # For special characters like ; and ?, they always force at least title case
                    # Replace special chars with letters to determine if it's all-uppercase pattern
                    test_trigger = special_trigger
                    for special, letter in [("?", "A"), (";", "A")]:
                        test_trigger = test_trigger.replace(special, letter)

                    # If test_trigger.upper() == test_trigger, it's uppercase pattern
                    if test_trigger.upper() == test_trigger:
                        special_replacement = apply_case_to_replacement_text(
                            test_trigger, replacement
                        )
                    else:
                        # For mixed case with special chars, force title case by creating
                        # a trigger that has the first alphabetic char as uppercase
                        alphabetic_chars = [
                            c for c in test_trigger if c.isalpha()
                        ]
                        if alphabetic_chars:
                            # Create a version where first alphabetic char is uppercase
                            title_trigger = ""
                            first_alpha_done = False
                            for c in test_trigger:
                                if c.isalpha() and not first_alpha_done:
                                    title_trigger += c.upper()
                                    first_alpha_done = True
                                else:
                                    title_trigger += (
                                        c.lower() if c.isalpha() else c
                                    )
                            special_replacement = (
                                apply_case_to_replacement_text(
                                    title_trigger, replacement
                                )
                            )
                        else:
                            special_replacement = replacement
                    variants.append((special_trigger, special_replacement))
                    seen_triggers.add(special_trigger)

    return variants


def apply_mixed_case_to_replacement(
    mixed_trigger: str, target_text: str
) -> str:
    """
    Apply mixed case pattern from trigger to replacement text.
    For patterns like aB -> Cd (first lower, second upper -> first upper, second lower)

    Args:
        mixed_trigger: The mixed case trigger
        target_text: The text to apply case to

    Returns:
        The target text with mixed case applied
    """
    if len(mixed_trigger) == 2 and len(target_text) >= 2:
        # Pattern aB -> Cd
        if mixed_trigger[0].islower() and mixed_trigger[1].isupper():
            return target_text[0].upper() + target_text[1:].lower()

    # Fallback to title case
    return target_text.capitalize()


def apply_case_to_replacement_text(
    original_trigger: str, target_text: str
) -> str:
    """
    Apply the case pattern from trigger to the target text.

    Args:
        original_trigger: The trigger text that defines the case pattern
        target_text: The text to apply the case pattern to

    Returns:
        The target text with case applied based on the trigger pattern
    """
    # Extract only alphabetic characters to determine case pattern
    alphabetic_chars = [char for char in original_trigger if char.isalpha()]

    # Check for special "uppercase" characters like ; and ?
    has_special_uppercase = any(char in [";", "?"] for char in original_trigger)

    if not alphabetic_chars:
        # No alphabetic characters, return original
        return target_text

    # Special case: for single alphabetic character, uppercase gives title case
    if len(alphabetic_chars) == 1 and alphabetic_chars[0].isupper():
        return target_text.capitalize()

    # Check if all alphabetic characters are uppercase
    all_alphabetic_uppercase = all(char.isupper() for char in alphabetic_chars)

    if all_alphabetic_uppercase and len(alphabetic_chars) > 1:
        return target_text.upper()
    # Check if it follows title case pattern (first alphabetic char uppercase)
    elif alphabetic_chars[0].isupper():
        return target_text.capitalize()
    # If has special uppercase chars (like ;), force at least title case
    elif has_special_uppercase:
        return target_text.capitalize()
    # All lowercase alphabetic characters
    else:
        return target_text.lower()


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
        special_upper_triggers = {",": [";", " ;", " :"], "'": ["?", " ?"]}
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
    special_upper_keys = {"'": ["?", " ?"]}
    new_map = []
    for key_char, value in mapping:
        key_lower = key_char.lower()
        key_upper = key_char.upper()
        out_lower = get_output_for_case(is_trigger_upper, False, value)
        out_upper = get_output_for_case(is_trigger_upper, True, value)
        new_map.append((key_lower, out_lower))
        if key_upper != key_lower:
            # i.e. is not a symbol, because symbols don’t have an uppercase version
            new_map.append((key_upper, out_upper))
        elif key_char in special_upper_keys:
            for special in special_upper_keys[key_char]:
                new_map.append((special, out_upper))

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

    def escape_part(part: str) -> str:
        for char, esc in XML_ESCAPE_TABLE.items():
            part = part.replace(char, esc)
        return part

    escaped_parts = [escape_part(part) for part in parts]

    # Reconstruct while preserving original entities
    result = "".join(
        p + (e if i < len(entities) else "")
        for i, (p, e) in enumerate(zip(escaped_parts, entities + [""]))
    )

    return result


# Fonction inverse : unescape_xml_characters
def unescape_xml_characters(value: str) -> str:
    """
    Remplace les entités XML par leur caractère original.
    Les séquences déjà échappées (&#xNNNN;) sont restaurées.
    """
    if not value:
        return value

    # Regex to detect numeric XML entities like &#x0026;
    numeric_entity_pattern = re.compile(r"&#x[0-9A-Fa-f]+;")

    # Split by numeric entities, unescape only entities
    parts = numeric_entity_pattern.split(value)
    entities = numeric_entity_pattern.findall(value)

    def unescape_entity(entity: str) -> str:
        return XML_UNESCAPE_TABLE.get(entity, entity)

    # Reconstruct while replacing known entities
    result = "".join(
        p + (unescape_entity(e) if i < len(entities) else "")
        for i, (p, e) in enumerate(zip(parts, entities + [""]))
    )
    return result
