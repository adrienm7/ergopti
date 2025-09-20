import logging
from pprint import pprint

from utilities.mappings_functions import (
    add_case_sensitive_mappings,
    escape_symbols_in_mappings,
)

logger = logging.getLogger("ergopti")

plus_mappings = {
    "comma_j_letters_sfbs": {
        "trigger": ",",
        "map": [
            ("a", "ja"),
            ("à", "j"),
            ("e", "je"),
            ("é", "jé"),
            ("ê", "ju"),
            ("i", "ji"),
            ("o", "jo"),
            ("u", "ju"),
            ("'", "j’"),
            ("’", "j’"),
            # Far letters
            ("c", "ç"),
            ("è", "z"),
            ("s", "qu"),
            ("x", "où"),
            ("y", "k"),
            # SFBs
            ("d", "ds"),
            ("f", "fl"),
            ("g", "gl"),
            ("h", "ph"),
            ("l", "cl"),
            ("m", "ms"),
            ("n", "nl"),
            ("p", "xp"),
            ("q", "qu’"),
            ("r", "rq"),
            ("t", "pt"),
            ("v", "dv"),
            ("z", "bj"),
        ],
    },
    "a_grave_suffixes": {
        "trigger": "à",
        "map": [
            # SFBs with "bu" or "ub"
            ("j", "bu"),
            # ("★", "bu"),
            ("u", "ub"),
            # Common suffixes
            ("a", "aire"),
            ("c", "ction"),
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
    "roll_ck": {
        "trigger": "c",
        "map": [
            ("x", "ck"),
        ],
    },
    "e": {
        "trigger": "e",
        "map": [
            ("é", "ez"),
            ("ê", "eo"),
        ],
    },
    "e_acute_sfb": {
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
    "e_circumflex_deadkey": {
        "trigger": "ê",
        "map": [
            ("a", "â"),
            ("à", "æ"),
            ("e", "oe"),
            ("é", "aî"),
            ("i", "î"),
            ("j", "œu"),  # Different than the AutoHotkey version
            # ("★", "œu"),
            ("o", "ô"),
            ("u", "û"),
        ],
    },
    "roll_wh": {
        "trigger": "h",
        "map": [
            ("c", "wh"),
        ],
    },
    "roll_ct": {
        "trigger": "p",
        "map": [
            ("'", "ct"),
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
    "roll_sk": {
        "trigger": "s",
        "map": [
            ("x", "sk"),
        ],
    },
    "y_e_grave": {
        "trigger": "y",
        "map": [
            ("è", "éi"),
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
    # ===============================
    # === Symbols and punctuation ===
    # ===============================
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


plus_mappings = add_case_sensitive_mappings(plus_mappings)
plus_mappings = escape_symbols_in_mappings(plus_mappings)


def check_duplicate_triggers(mappings: dict):
    """Check for duplicate trigger characters in the plus_mappings."""
    triggers = {}
    for key, data in mappings.items():
        trigger = data["trigger"]
        if trigger in triggers:
            logger.error(
                "Duplicate trigger '%s' found in '%s' and '%s'",
                trigger,
                key,
                triggers[trigger],
            )
        else:
            triggers[trigger] = key


check_duplicate_triggers(plus_mappings)

if __name__ == "__main__":
    pprint(plus_mappings, indent=2, width=120)
