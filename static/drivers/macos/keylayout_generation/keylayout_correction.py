"""Functions to correct and modify a keylayout content."""

import re

from data.symbol_names import ALIAS_TO_ENTITY
from tests.run_all_tests import validate_keylayout
from utilities.information_extraction import extract_keymap_body
from utilities.keyboard_id import set_unique_keyboard_id
from utilities.keylayout_sorting import sort_keylayout
from utilities.layer_names import replace_layer_names_in_file
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

    content = replace_keymapselect_mapindex_4(content)
    content = replace_keymapselect_mapindex_5(content)
    content = replace_keymapselect_mapindex_7(content)
    content = delete_keymap(content, 6)
    content = delete_keymap(content, 8)
    content = change_keymap_id(content, 7, 6)

    content = replace_modifier_map_id(content)
    content = replace_keymapset_id_with_iso(content)

    content = swap_keys(content, 10, 50)
    content = normalize_attribute_entities(content)
    content = replace_action_to_output_extra_keys(content)
    content = replace_layer_names_in_file(content)

    logger.info("%s➕ Modifying keymap 4…", LOGS_INDENTATION)
    keymap_0_content = extract_keymap_body(content, 0)
    keymap_content = modify_accented_letters_shortcuts(keymap_0_content)
    keymap_content = fix_ctrl_symbols(keymap_content)
    keymap_content = convert_actions_to_outputs(
        keymap_content
    )  # Ctrl shortcuts can be directly set to output, as they don’t trigger other states
    content = replace_keymap(content, 4, keymap_content)

    content = sort_keylayout(content)
    content = set_unique_keyboard_id(content)

    validate_keylayout(content)

    logger.info("Keylayout corrections complete.")
    return content


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


def replace_keymapset_id_with_iso(content: str) -> str:
    """
    Replace the id attribute value in <keyMapSet id="..."> with 'ISO', regardless of its original value.
    """
    logger.info(
        "%s🔹 Replacing <keyMapSet id=...> with id='ISO'…",
        LOGS_INDENTATION + "\t",
    )
    # Find the id value in <keyMapSet id="...">
    match = re.search(r'<keyMapSet\s+id="([^"]+)"', content)
    if not match:
        logger.warning(
            "%sNo <keyMapSet id=...> found.", LOGS_INDENTATION + "\t"
        )
        return content
    old_id = match.group(1)
    # Replace the id in <keyMapSet ...>
    content = re.sub(
        r'(<keyMapSet\s+id=")[^"]+("[^>]*>)', r"\1ISO\2", content, count=1
    )
    # Replace all references to the old id (e.g. mapSet="16c")
    content = re.sub(
        rf'(mapSet=")({re.escape(old_id)})(")', r"\1ISO\3", content
    )
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


def swap_keys(body: str, key1: int, key2: int) -> str:
    """Swap key codes."""
    logger.info(
        "%s🔹 Swapping key codes %d and %d…",
        LOGS_INDENTATION + "\t",
        key1,
        key2,
    )
    body = re.sub(f'code="{key2}"', "TEMP_CODE", body)
    body = re.sub(f'code="{key1}"', f'code="{key2}"', body)
    body = re.sub(r"TEMP_CODE", f'code="{key1}"', body)
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


def replace_action_to_output_extra_keys(body: str) -> str:
    """Replace action="..." to output="..." for extra keys."""

    def repl(match):
        code = int(match.group(1))
        if code in EXTRA_KEYS:
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


def replace_keymapselect_mapindex_4(body: str) -> str:
    """
    Replace the <keyMapSelect mapIndex="4">...</keyMapSelect> block with a fixed content.
    """
    logger.info(
        "%s🔹 Replacing keyMapSelect mapIndex=4…", LOGS_INDENTATION + "\t"
    )
    replacement = (
        '<keyMapSelect mapIndex="4">\n'
        '\t\t\t<modifier keys="anyControl anyOption? anyShift? caps? command?"/>\n'
        '\t\t\t<modifier keys="anyControl? anyOption? anyShift? caps? command"/>\n'
        "\t\t</keyMapSelect>"
    )

    pattern = r'<keyMapSelect mapIndex="4">.*?</keyMapSelect>'
    body = re.sub(pattern, replacement, body, flags=re.DOTALL)

    return body


def replace_keymapselect_mapindex_5(body: str) -> str:
    """
    Replace the <keyMapSelect mapIndex="5">...</keyMapSelect> block with a fixed content.
    """
    logger.info(
        "%s🔹 Replacing keyMapSelect mapIndex=5…", LOGS_INDENTATION + "\t"
    )
    replacement = (
        '<keyMapSelect mapIndex="5">\n'
        '\t\t\t<modifier keys="anyOption caps?"/>\n'
        "\t\t</keyMapSelect>"
    )

    pattern = r'<keyMapSelect mapIndex="5">.*?</keyMapSelect>'
    body = re.sub(pattern, replacement, body, flags=re.DOTALL)

    return body


def replace_keymapselect_mapindex_7(body: str) -> str:
    """
    Replace the <keyMapSelect mapIndex="7">...</keyMapSelect> block with a fixed content.
    """
    logger.info(
        "%s🔹 Replacing keyMapSelect mapIndex=7…", LOGS_INDENTATION + "\t"
    )
    replacement = (
        '<keyMapSelect mapIndex="7">\n'
        '\t\t\t<modifier keys="anyOption anyShift caps?"/>\n'
        "\t\t</keyMapSelect>"
    )

    pattern = r'<keyMapSelect mapIndex="7">.*?</keyMapSelect>'
    body = re.sub(pattern, replacement, body, flags=re.DOTALL)

    return body


def delete_keymap(body: str, keymap_index: int) -> str:
    """
    Remove the <keyMap index="{keymap_index}">...</keyMap> block from all <keyMapSet> sections
    and the corresponding <keyMapSelect mapIndex="{keymap_index}">...</keyMapSelect> block from all <modifierMap> sections in the keylayout XML body.
    Args:
        body: The XML content as a string.
        keymap_index: The index of the <keyMap> and <keyMapSelect> blocks to remove.
    Returns:
        The XML content with the specified blocks removed.
    """
    logger.info(
        '%s🗑️ Deleting  <keyMapSelect mapIndex="%s"> and <keyMap index="%s"> blocks…',
        LOGS_INDENTATION,
        keymap_index,
        keymap_index,
    )

    logger.info(
        '%sRemoving <keyMapSelect mapIndex="%s"> blocks…',
        LOGS_INDENTATION + "\n",
        keymap_index,
    )
    keymapselect_pattern = (
        rf'\n\t*<keyMapSelect mapIndex="{keymap_index}".*?</keyMapSelect>'
    )
    body, _ = re.subn(keymapselect_pattern, "", body, flags=re.DOTALL)

    logger.info(
        '%sRemoving <keyMap index="%s"> blocks…',
        LOGS_INDENTATION + "\n",
        keymap_index,
    )
    keymap_pattern = rf'<keyMap index="{keymap_index}".*?</keyMap>'
    body, _ = re.subn(keymap_pattern, "", body, flags=re.DOTALL)

    return body


def change_keymap_id(body: str, old_index: int, new_index: int) -> str:
    """
    Change the id/index of a keymap in both <keyMap index="..."> and <keyMapSelect mapIndex="..."> blocks.
    Args:
        body: The XML content as a string.
        old_index: The current index/id to replace.
        new_index: The new index/id to set.
    Returns:
        The XML content with the updated keymap indices.
    """

    logger.info(
        "%s🔹 Changing keymap id from %s to %s in <keyMap> and <keyMapSelect> blocks…",
        LOGS_INDENTATION + "\t",
        old_index,
        new_index,
    )

    logger.info(
        '%sUpdating <keyMap index="%s"> to <keyMap index="%s">…',
        LOGS_INDENTATION + "\t\t",
        old_index,
        new_index,
    )
    body = re.sub(
        f'<keyMap index="{old_index}"', f'<keyMap index="{new_index}"', body
    )

    logger.info(
        '%sUpdating <keyMapSelect mapIndex="%s"> to <keyMapSelect mapIndex="%s">…',
        LOGS_INDENTATION + "\t\t",
        old_index,
        new_index,
    )
    body = re.sub(f'mapIndex="{old_index}"', f'mapIndex="{new_index}"', body)

    return body
