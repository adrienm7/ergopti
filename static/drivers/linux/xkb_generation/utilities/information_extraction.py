import html
import re

try:
    from lxml import etree as LET
except ImportError:
    LET = None


def extract_keymap_body(
    xml_text: str, index: int, keymapset_id: str = "ISO"
) -> str:
    """
    Extract the inner content of a <keyMap> by index from a specific <keyMapSet> block.

    Args:
        xml_text (str): The full XML text containing the keyMapSet blocks.
        index (int): The index of the keyMap to extract.
        keymapset_id (str, optional): The id of the keyMapSet to search in. Defaults to "ISO".

    Returns:
        str: The inner content of the <keyMap> block.

    Raises:
        ValueError: If the specified keyMapSet or keyMap is not found.
    """
    keymapset_match = re.search(
        rf'<keyMapSet id="{re.escape(keymapset_id)}">(.*?)</keyMapSet>',
        xml_text,
        flags=re.DOTALL,
    )
    if not keymapset_match:
        raise ValueError(f'<keyMapSet id="{keymapset_id}"> block not found.')
    keymapset_body = keymapset_match.group(1)
    keymap_match = re.search(
        rf'<keyMap index="{index}">(.*?)</keyMap>',
        keymapset_body,
        flags=re.DOTALL,
    )
    if not keymap_match:
        raise ValueError(
            f'<keyMap index="{index}"> block not found in <keyMapSet id="{keymapset_id}">'
        )
    return keymap_match.group(1)


def get_symbol(keymap_body: str, macos_code: int) -> str:
    """Extract the symbol (output or action) for a given macOS key code in a keyMap body. Returns the value (e.g. 'a', 'A', etc) or '' if not found. Décode les entités XML."""
    match = re.search(
        rf'<key[^>]*code="{macos_code}"[^>]*(output|action)="([^"]+)"',
        keymap_body,
    )
    if match:
        return html.unescape(match.group(2))
    return ""
