import re

from utilities.logger import logger

LOGS_INDENTATION = "\t"


def convert_actions_to_outputs(body: str) -> str:
    """Convert all action="..." attributes to output="..."."""
    logger.info(
        "%s🔹 Converting all action attributes to output…",
        LOGS_INDENTATION + "\t",
    )
    return re.sub(r'action="([^"]+)"', r'output="\1"', body)


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


def assign_layer_to_action_block_none(
    body: str, trigger_key: str, layer_name: str
) -> str:
    """
    Assigns a next state (layer) to a single <action id="..."> in the body.
    Modifies the default <when state="none"/> line to include a 'next' state.
    Works even if trigger_key is encoded as &lt; or &#x003C; in the XML.
    """
    logger.debug(
        '%sAssigning next state %s to <action id="%s">…',
        LOGS_INDENTATION + "\t",
        layer_name,
        trigger_key,
    )

    def repl(match):
        header, body, footer = match.groups()
        body = re.sub(
            r'<when state="none"[^>]*>',
            f'<when state="none" next="{layer_name}"/>',
            body,
        )
        return f"{header}{body}{footer}"

    pattern = rf'(<action id="{re.escape(trigger_key)}">)(.*?)(</action>)'
    body = re.sub(pattern, repl, body, flags=re.DOTALL)

    return body


def add_terminator_state(body: str, output: str, layer_name: int) -> str:
    """
    Add a <when state="sX" output="..."/> line inside the <terminators> block.
    Raises ValueError if the state already exists.
    """
    logger.debug(
        '%sAdding <when state="%s" output="%s"/> to <terminators>…',
        LOGS_INDENTATION + "\t",
        layer_name,
        output,
    )

    def repl(match):
        header, body, footer = match.groups()
        # Check if layer already exists
        if re.search(rf'<when state="{re.escape(layer_name)}"', body):
            raise ValueError(
                f"Layer {layer_name} already exists in <terminators> block."
            )
        new_line = f'\t<when state="{layer_name}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t{footer}"

    pattern = r"(<terminators>)(.*?)(</terminators>)"
    body = re.sub(pattern, repl, body, flags=re.DOTALL)

    return body


def ensure_key_uses_action_and_not_output(
    body: str, action_id: str, extra_keys: list[int]
) -> str:
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
                    if code in extra_keys:
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
    body: str, trigger: str, layer: int, output: str
) -> str:
    """
    Insert a new <when state="sX" output="..."/> line inside the <action id="..."> block.
    Raises a ValueError if a <when> with the same state already exists.
    """
    logger.debug(
        '%sAdding <when state="%s" output="%s"/> to <action id="%s">…',
        LOGS_INDENTATION + "\t",
        layer,
        output,
        trigger,
    )

    def repl(match):
        header, body, footer = match.groups()
        # Check if the state already exists
        if re.search(rf'state="{re.escape(layer)}"', body):
            raise ValueError(
                f'Action "{trigger}" already has state {layer} defined.'
            )
        new_line = f'\t<when state="{layer}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t\t{footer}"

    pattern = rf'(<action id="{re.escape(trigger)}">)(.*?)(</action>)'
    body = ensure_action_block_exists(body, trigger)
    body = re.sub(pattern, repl, body, flags=re.DOTALL)

    return body
