"""
Keylayout Plus generation utilities for Ergopti:
create a variant with extra dead key features and symbol modifications.
"""

import re

from data.keylayout_plus_mappings import plus_mappings
from data.lists import EXTRA_KEYS
from tests.run_all_tests import validate_keylayout
from utilities.keyboard_id import set_unique_keyboard_id
from utilities.keylayout_extraction import (
    extract_name_from_file,
    get_last_used_layer,
)
from utilities.keylayout_modification import modify_name_from_file
from utilities.keylayout_sorting import sort_keylayout
from utilities.layer_names import create_layer_name
from utilities.logger import logger
from utilities.output_action_modification import (
    add_action_when_state,
    add_terminator_state,
    assign_layer_to_action_block_none,
    ensure_action_block_exists,
    ensure_key_uses_action_and_not_output,
)
from utilities.output_modification import replace_action_to_output_extra_keys

LOGS_INDENTATION = "\t"


def create_keylayout_plus(content: str):
    """
    Create a '_plus' variant of the corrected keylayout, with extra actions.
    """
    logger.info("%s🔧 Starting keylayout plus creation…", LOGS_INDENTATION)

    name = extract_name_from_file(content)
    content = modify_name_from_file(content, f"{name} Plus")

    logger.info(
        "%s➕ Modifying AltGr and ShiftAltGr symbols for Ergopti+…",
        LOGS_INDENTATION,
    )
    content = ergopti_plus_altgr_modifications(content)
    content = ergopti_plus_shiftaltgr_modifications(content)

    logger.info(
        "%s➕ Adding dead key features for Ergopti+…",
        LOGS_INDENTATION,
    )
    start_layer = get_last_used_layer(content) + 1

    for i, (feature, data) in enumerate(plus_mappings.items()):
        layer_number = start_layer + i
        trigger_key = data["trigger"]
        layer_name = create_layer_name(layer_number, trigger_key)
        logger.info(
            "%s🔹 Adding feature '%s' with trigger '%s' at layer %s…",
            LOGS_INDENTATION + "\t",
            feature,
            trigger_key,
            layer_name,
        )

        if not data["map"]:
            continue

        # Create the new dead key
        content = ensure_key_uses_action_and_not_output(
            content, trigger_key, EXTRA_KEYS
        )
        content = ensure_action_block_exists(content, trigger_key)
        content = assign_layer_to_action_block_none(
            content, trigger_key, layer_name
        )
        content = add_terminator_state(content, trigger_key, layer_name)

        # Add all dead key outputs
        for trigger, output in data["map"]:
            logger.debug(
                "%s— Adding output '%s' + '%s' ➜ '%s'…",
                LOGS_INDENTATION + "\t\t",
                trigger_key,
                trigger,
                output,
            )

            # Ensure any <key ... output="trigger"> is converted to action="trigger"
            # This is necessary, otherwise the key will always have the same output, despite being in a dead key layer
            content = ensure_key_uses_action_and_not_output(
                content, trigger, EXTRA_KEYS
            )

            # Add the new output on the key when in the dead key layer
            content = add_action_when_state(
                content, trigger, layer_name, output
            )

    content = replace_action_to_output_extra_keys(content, EXTRA_KEYS)
    content = sort_keylayout(content)
    content = set_unique_keyboard_id(content)

    validate_keylayout(content)

    logger.success("Keylayout plus creation complete.")
    return content


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
        # output="Ç" → " !" (fine non-breaking space + !)
        body = re.sub(r'(<key[^>]*(output|action)=")Ç(")', r"\1 !\3", body)
        # output="Ù" → "Où"
        body = re.sub(r'(<key[^>]*(output|action)=")Ù(")', r"\1Où\3", body)
        return f"{header}{body}{footer}"

    for idx in (6, 7):
        body = re.sub(
            rf'(<keyMap index="{idx}">)(.*?)(</keyMap>)',
            replace_in_keymap,
            body,
            flags=re.DOTALL,
        )

    return body
