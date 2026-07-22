"""
Utility for modifying information from keylayout files.
"""

import re

from .logger import logger

LOGS_INDENTATION = "\t"


def modify_name_from_file(content: str, new_name: str) -> str:
    """
    Modifies the name string (e.g. My Key Layout)
    in the name attribute of the given file.
    """

    content = re.sub(r'name="([^"]+)"', f'name="{new_name}"', content)

    return content


def replace_keymap(body: str, index: int, new_body: str) -> str:
    """Replace an existing keyMap body while keeping the original <keyMap> tags."""
    logger.info("%s🔹 Replacing keymap %d…", LOGS_INDENTATION + "\t", index)
    return re.sub(
        rf'(<keyMap index="{index}">).*?(</keyMap>)',
        rf"\1{new_body}\2",
        body,
        flags=re.DOTALL,
    )


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


def replace_keymapselect(body: str, index: int, replacement: str) -> str:
    """
    Replace the <keyMapSelect mapIndex="7">...</keyMapSelect> block with a fixed content.
    """
    logger.info(
        "%s🔹 Replacing keyMapSelect mapIndex=%s…",
        LOGS_INDENTATION + "\t",
        index,
    )

    pattern = rf'<keyMapSelect mapIndex="{index}">.*?</keyMapSelect>'
    body = re.sub(pattern, replacement, body, flags=re.DOTALL)

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


def replace_keymapset_id_with_layout(content: str) -> str:
    """
    Replace the id attribute value in <keyMapSet id="..."> with 'layout', regardless of its original value.
    """
    logger.info(
        "%s🔹 Replacing <keyMapSet id=...> with id='layout'…",
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
        r'(<keyMapSet\s+id=")[^"]+("[^>]*>)', r"\1layout\2", content, count=1
    )
    # Replace all references to the old id (e.g. mapSet="16c")
    content = re.sub(
        rf'(mapSet=")({re.escape(old_id)})(")', r"\1layout\3", content
    )
    return content


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
