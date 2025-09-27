import html
import re

from .cleaning import clean_invalid_xml_chars

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


def extract_deadkey_triggers(keylayout_path):
    """Return a dict: macOS action id -> deadkey name (dead_1, dead_2, ...) if next='sX' is present."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return {}
    print(f"[INFO] Extracting deadkey triggers from {keylayout_path}")
    with open(keylayout_path, encoding="utf-8") as file_in:
        xml_text = file_in.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    deadkey_map = {}
    if actions is not None:
        for action in actions.findall("action"):
            action_id = action.attrib.get("id")
            for when in action.findall("when"):
                next_attr = when.attrib.get("next")
                if (
                    next_attr
                    and next_attr.startswith("s")
                    and next_attr[1:].isdigit()
                ):
                    deadkey_map[action_id] = f"dead_{int(next_attr[1:])}"
    return deadkey_map


def build_deadkey_symbol_map(keylayout_path):
    """Construit la table deadkey_name -> unicode_symbol."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return {}
    with open(keylayout_path, encoding="utf-8") as file_in:
        xml_text = file_in.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    deadkey_symbol = {}
    if actions is not None:
        for action in actions.findall("action"):
            action_id = action.attrib.get("id")
            for when in action.findall("when"):
                state = when.attrib.get("state")
                output = when.attrib.get("output")
                if not output:
                    continue
                if state and state.startswith("s") and state[1:].isdigit():
                    deadkey_name = f"dead_{int(state[1:])}"
                    if action_id and action_id not in deadkey_symbol:
                        deadkey_symbol[deadkey_name] = output
    return deadkey_symbol
