"""Functions to correct and modify a keylayout content."""

import re

from tests.run_all_tests import validate_keylayout
from utilities.ansi_layout_fix import (
    add_ansi_keymapset_with_10_50,
    replace_keymapset_id_with_iso,
    replace_layouts_block,
)
from utilities.information_extraction import extract_keymap_body, swap_keys
from utilities.keyboard_id import set_unique_keyboard_id
from utilities.keylayout_sorting import sort_keylayout
from utilities.logger import logger

LOGS_INDENTATION = "\t"
EXTRA_KEYS = list(range(51, 151)) + [24, 27]


def correct_keylayout(content: str) -> str:
    """
    Apply all necessary corrections and modifications to a keylayout content.
    Returns the fully corrected content.
    """
    logger.info("%s🔧 Starting keylayout corrections…", LOGS_INDENTATION)

    logger.info("%s🔹 Removing XML comments…", LOGS_INDENTATION + "\t")
    content = re.sub(r"<!--.*?-->\n", "", content, flags=re.DOTALL)

    logger.info(
        "%s🔹 Removing empty lines at start and end…", LOGS_INDENTATION + "\t"
    )
    content = re.sub(r"^(\s*\n)+|((\s*\n)+)$", "", content)

    content = replace_modifier_map_id(content)
    content = replace_keymapset_id_with_iso(content)
    content = swap_keys(content, 10, 50)
    content = replace_layouts_block(content)

    content = normalize_attribute_entities(content)
    content = replace_action_to_output_extra_keys(content)

    logger.info("%s➕ Modifying keymap 4…", LOGS_INDENTATION)
    keymap_0_content = extract_keymap_body(content, 0)
    keymap_4_content = modify_accented_letters_shortcuts(keymap_0_content)
    keymap_4_content = fix_keymap_4_symbols(keymap_4_content)
    keymap_4_content = convert_actions_to_outputs(
        keymap_4_content
    )  # Ctrl shortcuts can be directly set to output, as they don’t trigger other states
    content = replace_keymap(content, 4, keymap_4_content)

    logger.info("%s➕ Adding keymap 9 as a copy of keymap 4…", LOGS_INDENTATION)
    content = add_keymap_select_9(content)
    keymap_4_content = extract_keymap_body(content, 4)
    content = add_keymap(content, 9, keymap_4_content)

    content = add_ansi_keymapset_with_10_50(content)
    content = sort_keylayout(content)
    content = set_unique_keyboard_id(content)

    validate_keylayout(content)

    logger.success("Keylayout corrections complete.")
    return content


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

    entity_normalization_map = {
        "&#x003C;": ["<", "&lt;"],
        "&#x003E;": [">", "&gt;"],
        "&#x0026;": ["&", "&amp;"],
        "&#x0022;": ['"', "&quot;"],
        "&#x0027;": ["'", "&apos;"],
    }

    alias_to_hex_entity = {
        alias: hex_entity
        for hex_entity, aliases in entity_normalization_map.items()
        for alias in aliases
    }

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
                    if entity in alias_to_hex_entity:  # Known named entity
                        normalized_chars.append(alias_to_hex_entity[entity])
                        i = semicolon_index + 1
                        continue
            # Raw character
            char = value[i]
            normalized_chars.append(alias_to_hex_entity.get(char, char))
            i += 1
        return "".join(normalized_chars)

    def replace_attribute(match):
        attr_name = match.group(1)
        # quote = match.group(2)  # Either " or ', but we force it to become "
        value = match.group(3)
        return f'{attr_name}="{normalize_value(value)}"'

    # Match attributes like output="...", output='...', action="..."
    return re.sub(r'(\w+)\s*=\s*(["\'])(.*?)\2', replace_attribute, body)


def replace_action_to_output_extra_keys(body: str) -> str:
    """Replace action="..." to output="..." for extra keys."""

    def repl(match):
        code = int(match.group(1))
        if code in EXTRA_KEYS:
            return match.group(0).replace('action="', 'output="')
        return match.group(0)

    pattern = r'<key code="(\d+)"([^>]*)action="[^"]*"([^>]*)>'
    fixed_body = re.sub(pattern, repl, body)

    # Special case: code=10 action="$" → output="$" (even if not in EXTRA_KEYS)
    fixed_body = re.sub(
        r'<key code="10"([^>]*)action="\$"([^>]*)>',
        r'<key code="10"\1output="$"\2>',
        fixed_body,
    )

    return fixed_body


def replace_modifier_map_id(content: str) -> str:
    """
    Replace all occurrences of the old modifierMap id (e.g., 'f4') with 'commonModifiers' in the XML content.
    This includes <layouts ... commonModifiers="f4"/> and <modifierMap id="f4" ...>.
    """
    logger.info(
        "%s🔹 Replacing all modifierMap id references with 'commonModifiers'…",
        LOGS_INDENTATION + "\t",
    )

    # Find the id value in <modifierMap id="...">
    match = re.search(r'\t?<modifierMap\s+id="([^"]+)"', content)
    if not match:
        logger.warning(
            "%sNo <modifierMap id=...> found.", LOGS_INDENTATION + "\t"
        )
        return content
    old_id = match.group(1)

    # Replace all occurrences of the old id in the content (as attribute value)
    content = re.sub(
        rf'([\s"=]){re.escape(old_id)}([\s"/])',
        r"\1commonModifiers\2",
        content,
    )
    return content


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


def convert_actions_to_outputs(body: str) -> str:
    """Convert all action="..." attributes to output="..."."""
    logger.info(
        "%s🔹 Converting all action attributes to output…",
        LOGS_INDENTATION + "\t",
    )
    return re.sub(r'action="([^"]+)"', r'output="\1"', body)


def replace_keymap(body: str, index: int, new_body: str) -> str:
    """Replace an existing keyMap body while keeping the original <keyMap> tags."""
    logger.info("%s🔹 Replacing keymap %d…", LOGS_INDENTATION + "\t", index)
    return re.sub(
        rf'(<keyMap index="{index}">).*?(</keyMap>)',
        rf"\1{new_body}\2",
        body,
        flags=re.DOTALL,
    )


def fix_keymap_4_symbols(body: str) -> str:
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


def add_keymap_select_9(body: str) -> str:
    """Add <keyMapSelect> entry for mapIndex 9."""
    logger.info(
        "%s🔹 Adding keymapSelect for index 9…", LOGS_INDENTATION + "\t"
    )
    key_map_select = """\t\t<keyMapSelect mapIndex="9">
\t\t\t<modifier keys="command caps? anyOption? control?"/>
\t\t\t<modifier keys="control caps? anyOption?"/>
\t\t</keyMapSelect>"""
    return re.sub(
        r'(<keyMapSelect mapIndex="8">.*?</keyMapSelect>)',
        r"\1\n" + key_map_select,
        body,
        flags=re.DOTALL,
    )


def add_keymap(body: str, index: int, keymap_body: str) -> str:
    """
    Add a keyMap with a given index just before the closing </keyMapSet> tag.
    If a keyMap with the same index already exists, the new keyMap is not added.
    """
    logger.info("%s🔹 Adding keymap %d…", LOGS_INDENTATION + "\t", index)
    if f'<keyMap index="{index}">' in body:
        logger.warning(
            "%sKeymap %d already exists, skipping.",
            LOGS_INDENTATION + "\t\t",
            index,
        )
        return body

    insertion = f'\n\t\t<keyMap index="{index}">{keymap_body}</keyMap>\n'
    # Insert just before the closing </keyMapSet> tag
    new_body = re.sub(
        r"(</keyMapSet>)", insertion + r"\1", body, flags=re.DOTALL
    )

    return new_body
