"""
Utility for adding fixed ANSI/ISO layouts block to keylayout files.
"""

import re

from .logger import logger

LOGS_INDENTATION = "\t"


def replace_layouts_block(content: str) -> str:
    """
    Replace the entire <layouts>...</layouts> block with a fixed block containing the provided layouts.
    """
    logger.info(
        "%s🔹 Replacing <layouts> block with fixed ANSI/ISO layouts…",
        LOGS_INDENTATION + "\t",
    )
    new_layouts = """\t<layouts>
    \t<layout first="0" last="0" mapSet="ISO" modifiers="commonModifiers"/>
    \t<layout first="1" last="6" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="10" last="10" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="12" last="12" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="14" last="15" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="24" last="24" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="27" last="28" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="37" last="37" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="40" last="40" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="195" last="195" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="198" last="198" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="204" last="204" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="202" last="202" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="34" last="34" mapSet="ANSI" modifiers="commonModifiers"/>
    \t<layout first="31" last="31" mapSet="ANSI" modifiers="commonModifiers"/>
\t</layouts>"""
    content = re.sub(
        r"\t?<layouts>.*?</layouts>",
        new_layouts,
        content,
        flags=re.DOTALL,
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


def add_ansi_keymapset_with_10_50(content: str) -> str:
    """
    2. Find the <keyMapSet id="ISO"> block and duplicate it as <keyMapSet id="ANSI">,
       but in the ANSI block, keep only <key> entries with code 10 or 50 in each <keyMap>.
    3. Insert the new ANSI block just after the ISO block.
    """
    logger.info(
        "%s🔹 Adding <keyMapSet id='ANSI'> with only key codes 10 and 50…",
        LOGS_INDENTATION + "\t",
    )

    # 2. Find the <keyMapSet id="ISO"> block
    iso_block_match = re.search(
        r'(<keyMapSet id="ISO">)(.*?)(</keyMapSet>)', content, re.DOTALL
    )
    if not iso_block_match:
        logger.warning(
            "%sNo <keyMapSet id='ISO'> block found.", LOGS_INDENTATION + "\t"
        )
        return content
    _, iso_body, _ = iso_block_match.groups()

    # Swap keys before extracting keymaps
    iso_body_swapped = swap_keys(iso_body, 10, 50)

    # 3. For each <keyMap ...> in ISO, create <keyMap index="N" baseMapSet="ISO" baseIndex="N"> with only key codes 10 and 50
    keymaps = re.findall(
        r'<keyMap index="(\d+)"[^>]*>(.*?)</keyMap>',
        iso_body_swapped,
        re.DOTALL,
    )
    ansi_keymaps = []
    for index, keymap_body in keymaps:
        filtered = "\n\t\t\t".join(
            re.findall(r'<key(?=[^>]*code="(?:10|50)")[^>]*/>', keymap_body)
        )
        ansi_keymaps.append(
            f'<keyMap index="{index}" baseMapSet="ISO" baseIndex="{index}">\n\t\t\t{filtered}\n\t\t</keyMap>'
        )
    ansi_body = "\n\t\t".join(ansi_keymaps)
    ansi_block = f'<keyMapSet id="ANSI">\n\t\t{ansi_body}\n\t</keyMapSet>'

    # Insert the ANSI block just before the ISO block
    insert_pos = iso_block_match.start()
    content = content[:insert_pos] + ansi_block + "\n\t" + content[insert_pos:]
    return content


def swap_keys(body: str, key1: int, key2: int) -> str:
    """Swap key codes 10 and 50."""
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
