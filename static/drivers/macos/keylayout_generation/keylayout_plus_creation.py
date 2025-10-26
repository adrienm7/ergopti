"""
Keylayout Plus generation utilities for Ergopti:
create a variant with extra dead key features and symbol modifications.
"""

import re

from data.lists import EXTRA_KEYS
from tests.run_all_tests import validate_keylayout
from utilities.keyboard_id import set_unique_keyboard_id
from utilities.keylayout_extraction import extract_version
from utilities.keylayout_modification import (
    modify_name_from_file,
)
from utilities.keylayout_sorting import sort_keylayout
from utilities.logger import logger
from utilities.output_action_modification import (
    ensure_action_block_exists,
)
from utilities.output_modification import replace_action_to_output_extra_keys

LOGS_INDENTATION = "\t"


def create_keylayout_plus(content: str, variant_number: int):
    """
    Create a '_plus' variant of the corrected keylayout, with extra actions.
    """
    logger.info("%s🔧 Starting keylayout plus creation…", LOGS_INDENTATION)

    version = extract_version(content)
    content = modify_name_from_file(content, f"Ergopti+ {version}")

    logger.info(
        "%s➕ Modifying AltGr and ShiftAltGr symbols for Ergopti+…",
        LOGS_INDENTATION,
    )
    content = ergopti_plus_magic_modifications(content)
    content = ergopti_plus_altgr_modifications(content)
    content = ergopti_plus_shiftaltgr_modifications(content)

    content = replace_action_to_output_extra_keys(content, EXTRA_KEYS)
    content = sort_keylayout(content)
    content = set_unique_keyboard_id(content, variant_number)

    validate_keylayout(content)

    logger.success("Keylayout plus creation complete.")
    return content


def ergopti_plus_magic_modifications(body: str) -> str:
    """
    - Replace <when state="none" ...> in <action id="j"> by output="★"
    - In <keyMap index="0">, set <key code="30" output="j"/>
    - In <keyMap index="6">, set <key code="30" action="¨"/>
    """
    logger.info(
        "%sAdding Magic key on key j and updating code 30 in layers 0 and 6…",
        LOGS_INDENTATION + "\t",
    )

    # Ensure <action id="j"> block exists
    body = ensure_action_block_exists(body, "j")

    # Replace <when state="none" ...> in <action id="j"> by output="★"
    def repl(match):
        header, block, footer = match.groups()
        block = re.sub(
            r'<when state="none"[^>]*>',
            '<when state="none" output="★"/>',
            block,
        )
        return f"{header}{block}{footer}"

    pattern = r'(<action id="j">)(.*?)(</action>)'
    body = re.sub(pattern, repl, body, flags=re.DOTALL)

    # Couche 0 : output="j"
    def repl0(match):
        header, body0, footer = match.groups()
        body0 = re.sub(r'\n\t\t\t<key[^>]*code="30"[^>]*/?>', "", body0)
        body0 = body0.rstrip() + '\n\t\t\t<key code="30" output="j"/>'
        return f"{header}{body0}{footer}"

    body = re.sub(
        r'(<keyMap index="0">)(.*?)(</keyMap>)', repl0, body, flags=re.DOTALL
    )

    # Couche 6 : action="¨"
    def repl6(match):
        header, body6, footer = match.groups()
        body6 = re.sub(r'\n\t\t\t<key[^>]*code="30"[^>]*/?>', "", body6)
        body6 = body6.rstrip() + '\n\t\t\t<key code="30" action="¨"/>'
        return f"{header}{body6}{footer}"

    body = re.sub(
        r'(<keyMap index="6">)(.*?)(</keyMap>)', repl6, body, flags=re.DOTALL
    )

    return body


def ergopti_plus_altgr_modifications(body: str) -> str:
    """
    In <keyMap index="5">:
      - If a <key ...> has output="ç" or action="ç", replace its output/action attributes
        with a single action="!".
      - If a <key ...> has output="œ" or action="œ", replace its output/action attributes
        with a single action="%".
      - If a <key ...> has output="ù" or action="ù", replace its output/action attributes
        with a single output="où".
      - Do NOT touch other <key> elements.
    After the keyMap modification, ensure <action id="!"> and <action id="%"> exist
    (inserted before the first </actions> if missing).
    """
    logger.info(
        "%sModifying AltGr symbols in <keyMap index=5>…",
        LOGS_INDENTATION + "\t",
    )

    def replace_in_keymap(match):
        header, body, footer = match.groups()

        def repl_key(key_match):
            key_tag = key_match.group(0)

            if re.search(r'(?:\boutput|\baction)="ç"', key_tag):
                new_tag = re.sub(r'\s+(?:output|action)="[^"]*"', "", key_tag)
                return (
                    new_tag[:-2].rstrip() + ' action="!"/>'
                    if new_tag.endswith("/>")
                    else new_tag[:-1].rstrip() + ' action="!">'
                )

            if re.search(r'(?:\boutput|\baction)="œ"', key_tag):
                new_tag = re.sub(r'\s+(?:output|action)="[^"]*"', "", key_tag)
                return (
                    new_tag[:-2].rstrip() + ' action="%"/>'
                    if new_tag.endswith("/>")
                    else new_tag[:-1].rstrip() + ' action="%">'
                )

            if re.search(r'(?:\boutput|\baction)="ù"', key_tag):
                new_tag = re.sub(r'\s+(?:output|action)="[^"]*"', "", key_tag)
                return (
                    new_tag[:-2].rstrip() + ' output="où"/>'
                    if new_tag.endswith("/>")
                    else new_tag[:-1].rstrip() + ' output="où">'
                )

            return key_tag

        body_fixed = re.sub(r"<key\b[^>]*\/?>", repl_key, body)
        return f"{header}{body_fixed}{footer}"

    pattern = r'(<keyMap index="5">)(.*?)(</keyMap>)'
    fixed = re.sub(pattern, replace_in_keymap, body, flags=re.DOTALL)

    fixed = ensure_action_block_exists(fixed, "!")
    fixed = ensure_action_block_exists(fixed, "%")

    return fixed


def ergopti_plus_shiftaltgr_modifications(body):
    logger.info(
        "%sModifying Shift+AltGr symbols in <keyMap index=6,7>…",
        LOGS_INDENTATION + "\t",
    )

    # This code replaces specific outputs in keymap index 6 = Shift + AltGr
    def replace_in_keymap(match):
        header, body, footer = match.groups()
        # output="Œ" ou action="Œ" → output=" %"
        body = re.sub(r'(<key[^>]*)(output|action)="Œ"', r'\1output=" %"', body)
        # output="Ç" ou action="Ç" → output=" !"
        body = re.sub(r'(<key[^>]*)(output|action)="Ç"', r'\1output=" !"', body)
        # output="Ù" ou action="Ù" → output="Où"
        body = re.sub(r'(<key[^>]*)(output|action)="Ù"', r'\1output="Où"', body)
        return f"{header}{body}{footer}"

    for idx in (6, 7):
        body = re.sub(
            rf'(<keyMap index="{idx}">)(.*?)(</keyMap>)',
            replace_in_keymap,
            body,
            flags=re.DOTALL,
        )

    return body
