mappings = {
    "e_circumflex_deadkey": {
        "trigger": "ê",
        "map": [
            ("à", "æ"),
            ("a", "â"),
            ("é", "aî"),
            ("e", "oe"),
            ("i", "î"),
            ("j", "œu"),
            ("★", "œu"),
            ("o", "ô"),
            ("u", "û"),
        ],
    },
    "comma_j_letters_sfbs": {
        "trigger": ",",
        "map": [
            ("à", "j"),
            ("a", "ja"),
            ("é", "jé"),
            ("ê", "ju"),
            ("e", "je"),
            ("i", "ji"),
            ("o", "jo"),
            ("u", "ju"),
            ("'", "j’"),
            ("’", "j’"),
            # Far letters
            ("è", "z"),
            ("y", "k"),
            ("c", "ç"),
            ("x", "où"),
            ("s", "qu"),
            # SFBs
            ("f", "fl"),
            ("g", "gl"),
            ("h", "ph"),
            ("z", "bj"),
            ("v", "dv"),
            ("n", "nl"),
            ("t", "pt"),
            ("r", "rq"),
            ("q", "qu’"),
            ("m", "ms"),
            ("d", "ds"),
            ("l", "cl"),
            ("p", "xp"),
        ],
    },
    "e": {
        "trigger": "e",
        "map": [
            ("é", "ez"),
            ("ê", "eo"),
        ],
    },
    "e_acute_sfbs": {
        "trigger": "é",
        "map": [
            ("ê", "â"),
        ],
    },
    "e_grave_y": {
        "trigger": "è",
        "map": [
            ("y", "ié"),
        ],
    },
    "y_e_grave": {
        "trigger": "y",
        "map": [
            ("è", "éi"),
        ],
    },
    "a_grave_suffixes": {
        "trigger": "à",
        "map": [
            # SFB with "bu" or "ub"
            ("j", "bu"),
            ("★", "bu"),
            ("u", "ub"),
            # Common suffixes
            ("a", "aire"),
            ("c", "ction"),
            ("cd", "could"),
            ("shd", "should"),
            ("d", "would"),
            ("é", "ying"),
            ("ê", "able"),
            ("f", "iste"),
            ("g", "ought"),
            ("h", "techn"),
            ("i", "ight"),
            ("k", "ique"),
            ("l", "elle"),
            ("p", "ence"),
            ("m", "isme"),
            ("n", "ation"),
            ("q", "ique"),
            ("r", "erre"),
            ("s", "ement"),
            ("t", "ettre"),
            ("v", "ment"),
            ("x", "ieux"),
            ("z", "ez-vous"),
            ("'", "ance"),
            ("’", "ance"),
        ],
    },
    "q_with_u": {
        "trigger": "q",
        "map": [
            ("a", "qua"),
            ("e", "que"),
            ("é", "qué"),
            ("è", "què"),
            ("ê", "quê"),
            ("i", "qui"),
            ("o", "quo"),
            ("'", "qu’"),
            ("’", "qu’"),
        ],
    },
    "typographic_apostrophe": {
        "trigger": "'",
        "map": [
            ("a", "’a"),
            ("e", "’e"),
            ("é", "’é"),
            ("è", "’è"),
            ("ê", "’ê"),
            ("h", "’h"),
            ("i", "’i"),
            ("o", "’o"),
            ("t", "’t"),
            ("u", "’u"),
            ("y", "’y"),
        ],
    },
    "roll_ct": {
        "trigger": "p",
        "map": [
            ("'", "ct"),
        ],
    },
    "roll_ck": {
        "trigger": "c",
        "map": [
            ("x", "ck"),
        ],
    },
    "roll_sk": {
        "trigger": "s",
        "map": [
            ("x", "sk"),
        ],
    },
    "roll_wh": {
        "trigger": "h",
        "map": [
            ("c", "wh"),
        ],
    },
    "rolls_hashtag": {
        "trigger": "#",
        "map": [
            ("!", " := "),
            ("(", '")'),
            ("[", '"]'),
        ],
    },
    "rolls_chevron_left": {
        "trigger": "<",
        "map": [
            ("@", "</"),
            ("%", " <= "),
        ],
    },
    "rolls_chevron_right": {
        "trigger": ">",
        "map": [
            ("%", " >= "),
        ],
    },
    "rolls_parenthesis_left": {
        "trigger": "(",
        "map": [
            ("#", '("'),
        ],
    },
    "rolls_bracket_left": {
        "trigger": "[",
        "map": [
            ("#", '["'),
            (")", ' = "'),
        ],
    },
    "rolls_bracket_right": {
        "trigger": "]",
        "map": [
            ("#", '"]'),
        ],
    },
    "rolls_exclamation_mark": {
        "trigger": "!",
        "map": [
            ("#", " != "),
        ],
    },
    "rolls_backslash": {
        "trigger": "\\",
        "map": [
            ('"', "/*"),
        ],
    },
    "rolls_quote": {
        "trigger": '"',
        "map": [
            ("\\", "*/"),
        ],
    },
    "rolls_dollar": {
        "trigger": "$",
        "map": [
            ("=", " => "),
        ],
    },
    "rolls_equal": {
        "trigger": "=",
        "map": [
            ("$", " <= "),
        ],
    },
    "rolls_plus": {
        "trigger": "+",
        "map": [
            ("?", " -> "),
        ],
    },
    "rolls_question_mark": {
        "trigger": "?",
        "map": [
            ("+", " <- "),
        ],
    },
}


def add_case_sensitive_mappings(orig_mappings: dict) -> dict:
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
    new_mappings = orig_mappings.copy()
    for key, data in orig_mappings.items():
        if not data.get("map"):
            continue
        process_mapping(new_mappings, key, data)
    return new_mappings


def process_mapping(new_mappings: dict, key: str, data: dict):
    """Process a single mapping entry and add all case-sensitive variants."""
    trigger = data["trigger"]
    trigger_variants = get_trigger_variants(trigger)
    for trigger_val, is_trigger_upper in trigger_variants:
        triggers_to_add = expand_special_trigger(trigger_val, is_trigger_upper)
        for actual_trigger in triggers_to_add:
            new_key_name = f"{key}_{actual_trigger}_map"
            new_map = build_case_map(data["map"], is_trigger_upper)
            new_mappings[new_key_name] = {
                "trigger": actual_trigger,
                "map": new_map,
            }


def get_trigger_variants(trigger: str) -> list[tuple[str, bool]]:
    """Return trigger variants: lowercase and uppercase."""
    return [(trigger, False), (trigger.upper(), True)]


def expand_special_trigger(trigger: str, is_upper: bool) -> list[str]:
    """Return list of actual triggers for special uppercase triggers."""
    special_upper_triggers = {",": [";", ":"]}
    if is_upper and trigger in special_upper_triggers:
        return special_upper_triggers[trigger]
    return [trigger]


def build_case_map(
    mapping: list[tuple[str, str]], is_trigger_upper: bool
) -> list[tuple[str, str]]:
    """
    Generate all key case combinations for a given trigger case.
    Applies output capitalisation rules.
    """
    new_map = []
    seen_keys = set()
    for key_char, value in mapping:
        for is_key_upper in [False, True]:
            key_case = key_char.upper() if is_key_upper else key_char
            if key_case in seen_keys:
                continue
            seen_keys.add(key_case)
            out = get_output_for_case(is_trigger_upper, is_key_upper, value)
            new_map.append((key_case, out))
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


def escape_symbols_in_mappings(orig_mappings: dict) -> dict:
    """
    Go through all mappings and replace XML-breaking characters in the outputs
    with their numeric character references, avoiding double escaping.
    """
    new_mappings = {}
    for key, data in orig_mappings.items():
        trigger = data["trigger"]
        if not data["map"]:
            new_mappings[key] = {"trigger": trigger, "map": []}
            continue

        fixed_map = []
        for trig, out in data["map"]:
            fixed_out = escape_xml_characters(out)
            fixed_map.append((escape_xml_characters(trig), fixed_out))

        new_mappings[key] = {"trigger": trigger, "map": fixed_map}

    return new_mappings


def escape_xml_characters(value: str) -> str:
    """
    Escape &, <, >, " in value for XML, but leave already escaped sequences intact.
    """
    if "&#x" in value:
        return value
    return (
        value.replace("&", "&#x0026;")
        .replace("<", "&#x003C;")
        .replace(">", "&#x003E;")
        .replace('"', "&#x0022;")
        .replace("'", "&#x0027;")
    )


# Apply case-sensitive mappings and escape XML characters
mappings = add_case_sensitive_mappings(mappings)
mappings = escape_symbols_in_mappings(mappings)
