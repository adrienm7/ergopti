"""
Utility for adding fixed ANSI/ISO layouts block to keylayout files.
"""

import re

from keylayout_generation.keylayout_correction import swap_keys

from ..logger import logger

LOGS_INDENTATION = "\t"


def add_ansi_fix(content: str) -> str:
    """
    Create a fixed ANSI keyMapSet.
    """
    logger.info("%s🔹 Adding an ANSI keyMapSet…", LOGS_INDENTATION + "\t")

    content = replace_layouts_block(content)
    content = add_ansi_keymapset_with_10_50(content)

    return content


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
    \t<layout first="50" last="50" mapSet="ANSI" modifiers="commonModifiers"/>
\t</layouts>"""
    content = re.sub(
        r"\t?<layouts>.*?</layouts>",
        new_layouts,
        content,
        flags=re.DOTALL,
    )
    return content


def add_ansi_keymapset_with_10_50(content: str) -> str:
    """
    2. Find the <keyMapSet id="ISO"> block and duplicate it as <keyMapSet id="ANSI">,
       but in the ANSI block, keep only <key> entries with code 10 or 50 in each <keyMap>.
    3. Insert the new ANSI block just before the ISO block.
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
        r'<keyMap\s*index="(\d+)"[^>]*>(.*?)</keyMap>',
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
