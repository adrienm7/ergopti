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


def add_uppercase_mappings(orig_mappings):
    """
    Generate mappings for uppercase triggers.
    - Alphabetic triggers become uppercase.
    - Special triggers can be replaced by one or more alternatives defined in `special_upper_triggers`.
    - All outputs are capitalized (titlecase).
    """
    # Define special triggers and their uppercase replacements (can be multiple)
    special_upper_triggers = {
        ",": [";", ":"],
    }

    new_mappings = orig_mappings.copy()  # Keep the original intact
    for key, data in orig_mappings.items():
        if len(data["map"]) == 0:
            continue
        trigger = data["trigger"]
        new_map = [(k, v.title()) for k, v in data["map"]]

        if trigger in special_upper_triggers:
            # Create a mapping for each replacement
            for i, replacement in enumerate(special_upper_triggers[trigger]):
                upper_key = f"{key}_upper{i}"
                new_mappings[upper_key] = {
                    "trigger": replacement,
                    "map": new_map,
                }
        elif trigger.isalpha():
            upper_key = key + "_upper"
            new_mappings[upper_key] = {
                "trigger": trigger.upper(),
                "map": new_map,
            }

    return new_mappings


def escape_symbols_in_mappings(orig_mappings):
    """
    Go through all mappings and replace every " character
    in the outputs with &#x0022; to avoid XML issues.
    """
    new_mappings = {}
    for key, data in orig_mappings.items():
        trigger = data["trigger"]
        fixed_map = []
        if len(data["map"]) == 0:
            new_mappings[key] = {
                "trigger": trigger,
                "map": [],
            }
            continue
        for trig, out in data["map"]:
            fixed_out = out.replace('"', "&#x0022;").replace("<", "&#x003C;")
            fixed_map.append((trig, fixed_out))
        new_mappings[key] = {
            "trigger": trigger,
            "map": fixed_map,
        }
    return new_mappings


mappings = add_uppercase_mappings(mappings)
mappings = escape_symbols_in_mappings(mappings)
