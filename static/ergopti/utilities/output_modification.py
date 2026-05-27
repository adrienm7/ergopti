import re

from data.symbol_names import ALIAS_TO_ENTITY

from utilities.keylayout_extraction import extract_keymap_body
from utilities.keylayout_modification import replace_keymap
from utilities.logger import logger

LOGS_INDENTATION = "\t"
EXTRA_KEYS = list(range(51, 151)) + [24, 27]


def fix_invalid_symbols(body: str) -> str:
    """
    Fix invalid XML symbols for <, > and &.
    This function won’t be necessary anymore in new versions of KbdEdit.
    """
    logger.info(
        "%s🔹 Fixing invalid symbols for <, > and &…", LOGS_INDENTATION + "\t"
    )
    body = body.replace("&lt;", "&#x003C;")  # <
    body = body.replace("&gt;", "&#x003E;")  # >
    body = body.replace("&amp;", "&#x0026;")  # &
    return body


def normalize_attribute_entities(body: str) -> str:
    """
    Normalize XML-breaking characters inside attribute values only.
    Converts <, >, &, ", ' (and named entities) into their hex escapes.
    Works for both single-quoted and double-quoted attributes, and multi-symbol values.
    """
    logger.info("%s🔹 Normalizing attribute entities…", LOGS_INDENTATION + "\t")

    def normalize_value(value: str) -> str:
        normalized_chars = []
        i = 0
        while i < len(value):
            if value[i] == "&":
                semicolon_index = value.find(";", i)
                if semicolon_index != -1:
                    entity = value[i : semicolon_index + 1]
                    if entity.startswith("&#x"):  # Already hex escape → keep
                        normalized_chars.append(entity)
                        i = semicolon_index + 1
                        continue
                    if entity in ALIAS_TO_ENTITY:  # Known named entity
                        normalized_chars.append(ALIAS_TO_ENTITY[entity])
                        i = semicolon_index + 1
                        continue
            # Raw character
            char = value[i]
            normalized_chars.append(ALIAS_TO_ENTITY.get(char, char))
            i += 1
        return "".join(normalized_chars)

    def replace_attribute(match):
        attr_name = match.group(1)
        value = match.group(3)
        return f'{attr_name}="{normalize_value(value)}"'

    # Match attributes like output="...", output='...', action="..."
    return re.sub(r'(\w+)\s*=\s*(["\'])(.*?)\2', replace_attribute, body)


def replace_action_to_output_extra_keys(
    body: str, extra_keys: list[int]
) -> str:
    """Replace action="..." to output="..." for extra keys."""

    def repl(match):
        code = int(match.group(1))
        if code in extra_keys:
            return match.group(0).replace('action="', 'output="')
        return match.group(0)

    pattern = r'<key code="(\d+)"([^>]*)action="[^"]*"([^>]*)>'
    fixed_body = re.sub(pattern, repl, body)

    # Special case: code=10/50 action="$" → output="$" (even if not in EXTRA_KEYS)
    fixed_body = re.sub(
        r'<key code="10"([^>]*)action="\$"([^>]*)>',
        r'<key code="10"\1output="$"\2>',
        fixed_body,
    )
    fixed_body = re.sub(
        r'<key code="50"([^>]*)action="\$"([^>]*)>',
        r'<key code="50"\1output="$"\2>',
        fixed_body,
    )

    # Replace action by output for the j key (8) on Shift + AltGr + J (layer 6)
    keymap_6 = extract_keymap_body(fixed_body, 6)
    new_keymap_6 = re.sub(
        r'(<key code="8") action="(.*)"',
        r'\1 output="\2"',
        keymap_6,
    )
    # Reinsert the modified keymap into the full body and update fixed_body.
    fixed_body = replace_keymap(fixed_body, 6, new_keymap_6)

    return fixed_body


def modify_accented_letters_shortcuts(body: str) -> str:
    """Replace the output value for accented letters key codes."""
    logger.info(
        "%s🔹 Modifying accented letter shortcuts…", LOGS_INDENTATION + "\t"
    )

    replacements = {
        "6": "c",
        "7": "v",
        "50": "x",
        "12": "z",
    }

    for code, new_value in replacements.items():
        # Replace the body inside output or action for the given code
        body = re.sub(
            rf'(<key code="{code}"[^>]*(output|action)=")[^"]*(")',
            rf"\1{new_value}\3",
            body,
        )

    return body


def fix_ctrl_symbols(body: str) -> str:
    """Correct the symbols for Ctrl + and Ctrl - in a keyMap body."""
    logger.info(
        "%s🔹 Fixing keymap 4 symbols in body…", LOGS_INDENTATION + "\t"
    )
    body = re.sub(
        r'(<key code="24"[^>]*(output|action)=")[^"]*(")', r"\1+\3", body
    )
    body = re.sub(
        r'(<key code="27"[^>]*(output|action)=")[^"]*(")', r"\1-\3", body
    )
    return body
