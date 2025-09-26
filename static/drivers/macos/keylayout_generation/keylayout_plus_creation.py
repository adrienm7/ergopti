"""
Keylayout Plus generation utilities for Ergopti:
create a variant with extra dead key features and symbol modifications.
"""

import re

from keylayout_correction import replace_action_to_output_extra_keys
from keylayout_plus_mappings import plus_mappings
from tests.run_all_tests import validate_keylayout
from utilities.keylayout_sorting import sort_keylayout

EXTRA_KEYS = [27] + list(range(51, 150))
from utilities.logger import logger

LOGS_INDENTATION = "\t"


def create_keylayout_plus(content: str):
    """
    Create a '_plus' variant of the corrected keylayout, with extra actions.
    """
    logger.info("%s🔧 Starting keylayout plus creation…", LOGS_INDENTATION)

    content = append_plus_to_layout_name(content)

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
        layer = start_layer + i
        trigger_key = data["trigger"]
        logger.info(
            "%s🔹 Adding feature '%s' with trigger '%s' at layer s%d…",
            LOGS_INDENTATION + "\t",
            feature,
            trigger_key,
            layer,
        )

        if not data["map"]:
            continue

        # Create the new dead key
        content = ensure_key_uses_action_and_not_output(content, trigger_key)
        content = ensure_action_block_exists(content, trigger_key)
        content = assign_layer_to_action_block_none(content, trigger_key, layer)
        content = add_terminator_state(content, layer, trigger_key)

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
            content = ensure_key_uses_action_and_not_output(content, trigger)

            # Add the new output on the key when in the dead key layer
            content = add_action_when_state(content, trigger, layer, output)

    content = replace_action_to_output_extra_keys(content)
    content = sort_keylayout(content)
    validate_keylayout(content)

    logger.success("Keylayout plus creation complete.")
    return content


def append_plus_to_layout_name(body: str) -> str:
    """
    Append ' Plus' to the keyboard name in the <keyboard> tag.
    """
    logger.info(
        "%sAppending ' Plus' to <keyboard> name…", LOGS_INDENTATION + "\t"
    )

    def repl(match):
        prefix, name, suffix = match.groups()
        if not name.endswith(" Plus"):
            name += " Plus"
        return f"{prefix}{name}{suffix}"

    pattern = r'(<keyboard\b[^>]*\bname=")([^"]+)(")'
    body = re.sub(pattern, repl, body)

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


def ensure_action_block_exists(body: str, action_id: str) -> str:
    """
    Ensure an <action id="..."> block exists.
    - Matches <action ... id="ID" ...> or <action ... id='ID' ...> wherever the id attribute is placed.
    - If missing, inserts the block before the closing </actions>, using the same indentation.
    """
    logger.debug(
        '%sEnsuring <action id="%s"> block exists…',
        LOGS_INDENTATION + "\t",
        action_id,
    )

    # Match <action ... id="action_id" ...> or with single quotes, id can be anywhere in the tag
    pattern = rf'<action\b[^>]*\bid\s*=\s*(["\']){re.escape(action_id)}\1'

    if not re.search(pattern, body):
        indentation = "\n\t\t"
        block = (
            f'{indentation}<action id="{action_id}">{indentation}'
            f'\t<when state="none" output="{action_id}"/>{indentation}'
            f"</action>"
        )

        # Insert the <action> block just before the end of the <actions> block
        body = re.sub(r"(\s*</actions>)", block + r"\1", body, count=1)

    return body


def get_last_used_layer(body: str) -> int:
    """
    Scan the keylayout body to find the highest layer number in use.
    Returns this number (not the next available one).
    Useful to get the last used layer, then add +1 if needed.
    """
    logger.info("%sScanning for last used layer…", LOGS_INDENTATION + "\t")

    # Find all numbers in 'state="sX"' and 'next="sX"'
    state_indices = [int(m) for m in re.findall(r'state="s(\d+)"', body)]
    next_indices = [int(m) for m in re.findall(r'next="s(\d+)"', body)]

    if state_indices or next_indices:
        max_layer = max(state_indices + next_indices)
    else:
        max_layer = 0

    logger.info("%sLast used layer: s%d", LOGS_INDENTATION + "\t", max_layer)
    return max_layer


def assign_layer_to_action_block_none(
    body: str, action_id: str, layer_num: int
) -> str:
    """
    Assigns a next state (layer) to a single <action id="..."> in the body.
    Modifies the default <when state="none"/> line to include a 'next' state.
    Works even if action_id is encoded as &lt; or &#x003C; in the XML.
    """
    logger.debug(
        '%sAssigning next state s%d to <action id="%s">…',
        LOGS_INDENTATION + "\t",
        layer_num,
        action_id,
    )

    def repl(match):
        header, body, footer = match.groups()
        body = re.sub(
            r'<when state="none"[^>]*>',
            f'<when state="none" next="s{layer_num}"/>',
            body,
        )
        return f"{header}{body}{footer}"

    pattern = rf'(<action id="{re.escape(action_id)}">)(.*?)(</action>)'
    body = re.sub(pattern, repl, body, flags=re.DOTALL)

    return body


def add_terminator_state(body: str, state_number: int, output: str) -> str:
    """
    Add a <when state="sX" output="..."/> line inside the <terminators> block.
    Raises ValueError if the state already exists.
    """
    logger.debug(
        '%sAdding <when state="s%d" output="%s"/> to <terminators>…',
        LOGS_INDENTATION + "\t",
        state_number,
        output,
    )

    def repl(match):
        header, body, footer = match.groups()
        # Check if state already exists
        if re.search(rf'<when state="s{state_number}"', body):
            raise ValueError(
                f"State s{state_number} already exists in <terminators> block."
            )
        new_line = f'\t<when state="s{state_number}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t{footer}"

    pattern = r"(<terminators>)(.*?)(</terminators>)"
    body = re.sub(pattern, repl, body, flags=re.DOTALL)

    return body


def ensure_key_uses_action_and_not_output(body: str, action_id: str) -> str:
    """
    Ensure that in <keyMap index="0|1|2|3|5|6|7|8"> blocks,
    any <key ... output="action_id" or action="action_id"> becomes
    <key ... action="action_id"> (preserving other attributes),
    but only for keys whose code is NOT in EXTRA_KEYS.
    """
    logger.debug(
        "%sEnsuring <key> uses action '%s' in keymaps 0, 1, 2, 3, 5, 6, 7, 8…",
        LOGS_INDENTATION + "\t",
        action_id,
    )
    for idx in (0, 1, 2, 3, 5, 6, 7, 8):
        pattern = rf'(<keyMap index="{idx}">)(.*?)(</keyMap>)'

        def repl_keymap(m):
            header, content, footer = m.groups()

            def key_repl(km):
                tag = km.group(0)
                code_match = re.search(r'code="(\d+)"', tag)
                code = int(code_match.group(1)) if code_match else None
                if re.search(rf'(output|action)="{re.escape(action_id)}"', tag):
                    new_tag = re.sub(r'\s+(output|action)="[^"]*"', "", tag)
                    if code in EXTRA_KEYS:
                        new_tag = (
                            new_tag[:-2].rstrip() + f' output="{action_id}"/>'
                        )
                    else:
                        new_tag = (
                            new_tag[:-2].rstrip() + f' action="{action_id}"/>'
                        )
                    return new_tag
                return tag

            new_content = re.sub(r"<key\b[^>]*?/?>", key_repl, content)
            return f"{header}{new_content}{footer}"

        body = re.sub(pattern, repl_keymap, body, flags=re.DOTALL)
    return body


def add_action_when_state(
    body: str, action_id: str, state_number: int, output: str
) -> str:
    """
    Insert a new <when state="sX" output="..."/> line inside the <action id="..."> block.
    Raises a ValueError if a <when> with the same state already exists.
    """
    logger.debug(
        '%sAdding <when state="s%d" output="%s"/> to <action id="%s">…',
        LOGS_INDENTATION + "\t",
        state_number,
        output,
        action_id,
    )

    def repl(match):
        header, body, footer = match.groups()

        # Check if the state already exists
        if re.search(rf'state="s{state_number}"', body):
            raise ValueError(
                f'Action "{action_id}" already has state s{state_number} defined.'
            )

        new_line = f'\t<when state="s{state_number}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t\t{footer}"

    pattern = rf'(<action id="{re.escape(action_id)}">)(.*?)(</action>)'
    body = ensure_action_block_exists(body, action_id)
    body = re.sub(pattern, repl, body, flags=re.DOTALL)

    return body
