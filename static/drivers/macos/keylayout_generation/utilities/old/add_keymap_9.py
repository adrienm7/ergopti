import re

from ..information_extraction import extract_keymap_body
from ..logger import logger

LOGS_INDENTATION = "\t\t"


def add_keymap_9(content: str) -> str:
    """
    Create keymap 9 as a copy of keymap 4.
    """
    logger.info("%s➕ Adding keymap 9 as a copy of keymap 4…", LOGS_INDENTATION)

    content = add_keymap_select_9(content)
    keymap_4_content = extract_keymap_body(content, 4)
    content = add_keymap(content, 9, keymap_4_content)

    return content


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
