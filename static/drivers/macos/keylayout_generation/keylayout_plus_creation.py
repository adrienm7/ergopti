import re

from keylayout_plus_mappings import escape_xml_characters, mappings

LOGS_INDENTATION = "\t"


def create_keylayout_plus(content: str):
    """
    Create a '_plus' variant of the corrected keylayout, with extra actions.
    """

    content = (
        content.replace('output="\'"', "output='&#x0027;'")
        .replace('action="\'"', 'action="&#x0027;"')
        .replace('id="\'"', 'id="&#x0027;"')
        .replace('output="<"', 'output="&#x003C;"')
        .replace('action="<"', 'action="&#x003C;"')
        .replace('id="<"', 'id="&#x003C;"')
        .replace('output=">"', 'output="&#x003E;"')
        .replace('action=">"', 'action="&#x003E;"')
        .replace('id=">"', 'id="&#x003E;"')
    )

    content = content.replace("&lt;", "&#x003C;")
    content = content.replace("&gt;", "&#x003E;")
    content = content.replace("&amp;", "&#x0026;")
    content = content.replace("&quot;", "&#x0022;")
    content = content.replace("&apos;", "&#x0027;")

    content = append_plus_to_keyboard_name(content)
    content = ergopti_plus_altgr_symbols(content)
    content = ergopti_plus_shiftaltgr_symbols(content)

    start_layer = find_next_available_layer(content)
    for i, (feature, data) in enumerate(mappings.items()):
        layer = start_layer + i
        trigger_key = data["trigger"]
        trigger_key = escape_xml_characters(trigger_key)
        print(
            f"\t\tAdding feature '{feature}' with trigger '{trigger_key}' at layer s{layer}"
        )

        if len(data["map"]) == 0:
            continue

        # Assign trigger key to this layer
        content = ensure_action_block(content, trigger_key, trigger_key)
        content = assign_action_layer(content, trigger_key, layer)

        # Add trigger key as dead key
        content = add_terminator_state(content, layer, trigger_key)

        # Add all feature actions
        for action_id, output in data["map"]:
            action_id = escape_xml_characters(action_id)
            print(f"\t\t\tAdding action '{action_id}' ➜ '{output}'")

            # Ensure any <key ... output="action_id"> is converted to action="action_id"
            # This preserves key codes/modifiers and avoids having <key ... output="..."> which would break action linking
            content = ensure_key_uses_action(content, action_id)

            # Now add the when state to the corresponding <action id="..."> (ensure_action_block is called inside)
            content = add_action_state(content, action_id, layer, output)

    # Correct problem of the " character
    content = (
        content.replace('id="""', "id='\"'")
        .replace('output="""', "output='\"'")
        .replace('<key code="8" output=\'"\'/>', '<key code="8" action=\'"\'/>')
        .replace('"/>"/>', '"/>')
        .replace('output="<"', 'output="&#x003C;"')
        .replace("'\"'", "'&#x0022;'")
    )

    # Enter
    # content = ensure_key_action(content, 36, "Enter", "&#x000D;")

    # # Tab
    # content = ensure_key_action(content, 48, "Tab", "&#x0009;")

    # # Escape
    # content = ensure_key_action(content, 53, "Escape", "&#x001B;")

    # # Space
    # content = ensure_key_action(content, 49, "Space", "&#x0020;")

    # problematic = [
    #     (36, "Enter", "&#x000A;"),  # Return / Enter -> LF
    #     (48, "Tab", "&#x0009;"),  # Tab
    #     (53, "Escape", "&#x001B;"),  # Escape
    #     (49, "Space", "&#x0020;"),  # Space
    # ]

    # for action_id, name, output in problematic:
    #     content = ensure_key_uses_action(content, action_id)
    #     content = add_action_state(content, action_id, layer, output)
    return content


def ensure_key_action(
    content: str,
    key_code: int,
    action_id: str,
    xml_output: str,
    max_state: int = 100,
) -> str:
    """
    Ensure a key uses an action and has all states up to max_state.

    Parameters:
    - key_code: code attribute of the <key>
    - action_id: id for the <action> element
    - xml_output: output for each <when state="sX"/>
    - max_state: number of states to create (default 100)
    """
    # Make the <key> use action="xml_output"
    content = re.sub(
        rf'(<key\s+code="{key_code}")([^>]*)/>',
        rf'\1 action="{xml_output}"/>',
        content,
    )

    max_state = find_next_available_layer(content) - 1

    # Create <action id="xml_output"> with all states if missing
    if not re.search(rf'<action\s+id="{re.escape(xml_output)}">', content):
        m = re.search(r"(?m)^(?P<indent>\s*)</actions>", content)
        indent = m.group("indent") if m else "\t\t"
        # Add state="none" plus s1..s{max_state}
        states = "\n".join(
            [f'{indent}\t\t<when state="none" output="{xml_output}"/>']
            + [
                f'{indent}\t\t<when state="s{i}" output="{xml_output}"/>'
                for i in range(1, max_state + 1)
            ]
        )
        action_block = f'{indent}\t<action id="{xml_output}">\n{states}\n\t{indent}</action>\n'
        if m:
            content = content[: m.start()] + action_block + content[m.start() :]
        else:
            content += action_block
    else:
        # Add missing states to existing action, including state="none"
        if not re.search(
            rf'<action\s+id="{re.escape(xml_output)}">.*<when state="none"',
            content,
            re.DOTALL,
        ):
            content = re.sub(
                rf'(<action\s+id="{re.escape(xml_output)}">.*?)(</action>)',
                rf'\1\t\t<when state="none" output="{xml_output}"/>\n\2',
                content,
                flags=re.DOTALL,
            )
        for i in range(1, max_state + 1):
            if not re.search(
                rf'<action\s+id="{re.escape(xml_output)}">.*<when state="s{i}"',
                content,
                re.DOTALL,
            ):
                content = re.sub(
                    rf'(<action\s+id="{re.escape(xml_output)}">.*?)(</action>)',
                    rf'\1\t\t<when state="s{i}" output="{xml_output}"/>\n\2',
                    content,
                    flags=re.DOTALL,
                )

    return content


def ensure_key_uses_action(content: str, action_id: str) -> str:
    """
    Ensure that in <keyMap index="1|2|3|5"> blocks,
    any <key ... output="action_id" or action="action_id"> becomes
    <key ... action="action_id"> (preserving other attributes).
    Only modifies <key> tags that actually reference the action_id;
    leaves other keyMaps untouched.
    """

    literal = re.escape(action_id)
    hex_variants = []
    if len(action_id) == 1:
        codepoint = ord(action_id)
        hex_variants = [f"&#x{codepoint:04X};", f"&#x{codepoint:04x};"]

    def process_keymap(match):
        # use explicit group access to avoid unpacking issues
        header = match.group(1)
        body = match.group(2)
        footer = match.group(3)

        def repl_key(tag_match):
            tag = tag_match.group(0)
            found = False
            if re.search(rf'\b(?:output|action)="{literal}"', tag):
                found = True
            else:
                for hv in hex_variants:
                    if re.search(
                        rf'\b(?:output|action)="{re.escape(hv)}"', tag
                    ):
                        found = True
                        break

            if not found:
                return tag  # leave untouched

            # remove only output="..." and action="..."
            new_tag = re.sub(r'\s+(?:output|action)="[^"]*"', "", tag)

            # insert the unified action="..."
            if new_tag.endswith("/>"):
                new_tag = new_tag[:-2].rstrip() + f' action="{action_id}"/>'
            else:
                new_tag = new_tag[:-1].rstrip() + f' action="{action_id}">'
            return new_tag

        body = re.sub(r"<key\b[^>]*\/?>", repl_key, body)
        return f"{header}{body}{footer}"

    # NON-CAPTURING group for the index alternation to ensure exactly 3 capture groups
    pattern = r'(<keyMap index="(?:1|2|3|5)">)(.*?)(</keyMap>)'
    return re.sub(pattern, process_keymap, content, flags=re.DOTALL)


def append_plus_to_keyboard_name(content: str) -> str:
    """
    Appends ' Plus' to the keyboard name in the <keyboard> tag.
    """
    pattern = r'(<keyboard\b[^>]*\bname=")([^"]+)(")'

    def repl(match):
        prefix, name, suffix = match.groups()
        if not name.endswith(" Plus"):
            name += " Plus"
        return f"{prefix}{name}{suffix}"

    return re.sub(pattern, repl, content)


def ergopti_plus_altgr_symbols(content: str) -> str:
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
    fixed = re.sub(pattern, replace_in_keymap, content, flags=re.DOTALL)

    fixed = ensure_action_block(fixed, "!", "!")
    fixed = ensure_action_block(fixed, "%", "%")

    return fixed


def ensure_action_block(doc: str, action_id: str, output_value: str) -> str:
    """
    Ensure an <action id="..."> block exists.
    - Matches <action ... id="ID" ...> or <action ... id='ID' ...> wherever the id attribute is placed.
    - If missing, inserts the block before the first </actions>, using the same indentation.
    """
    if action_id == "<":
        action_id = "&lt;"
    if action_id == ">":
        action_id = "&gt;"
    # Match <action ... id="action_id" ...> or with single quotes, id can be anywhere in the tag
    pattern = rf'<action\b[^>]*\bid\s*=\s*(["\']){re.escape(action_id)}\1'

    if not re.search(pattern, doc):
        # Try to detect indentation of the closing </actions> to keep style consistent
        m = re.search(r"^(?P<indent>\s*)</actions>", doc, flags=re.MULTILINE)
        indent = m.group("indent") if m else "\t"

        block = (
            f'{indent}<action id="{action_id}">\n'
            f'{indent}\t\t<when state="none" output="{output_value}"/>\n'
            f"{indent}\t</action>\n{indent}"
        )

        # Insert the block right before the first </actions>
        doc = re.sub(r"(</actions>)", block + r"\1", doc, count=1)

    return doc


def ergopti_plus_shiftaltgr_symbols(content):
    # This code replaces specific outputs in keymap index 6 = Shift + AltGr
    def replace_in_keymap(match):
        header, body, footer = match.groups()
        # output="Ç" → " !" (fine non-breaking space + !)
        body = re.sub(r'(<key[^>]*(output|action)=")Ç(")', r"\1 !\3", body)
        # output="Ù" → "Où"
        body = re.sub(r'(<key[^>]*(output|action)=")Ù(")', r"\1Où\3", body)
        return f"{header}{body}{footer}"

    for idx in (6, 7):
        content = re.sub(
            rf'(<keyMap index="{idx}">)(.*?)(</keyMap>)',
            replace_in_keymap,
            content,
            flags=re.DOTALL,
        )

    return content


def find_next_available_layer(content: str) -> int:
    """
    Scans the keylayout content to find the highest layer number in use
    and returns the next available layer number.
    """
    # Find all 'when state="sX"' numbers
    state_indices = [int(m) for m in re.findall(r'state="s(\d+)"', content)]
    # Find all 'next="sX"' numbers
    next_indices = [int(m) for m in re.findall(r'next="s(\d+)"', content)]

    max_layer = max(state_indices + next_indices, default=0)
    next_layer = max_layer + 1
    print(f"\t\tNext available layer: s{next_layer}")
    return next_layer


def create_uppercase_mapping(mapping, titlecase=False):
    """
    Given a mapping of lowercase keys to outputs, generate a mapping for uppercase keys.
    Only letters are uppercased; other symbols are left unchanged.
    """
    uppercase_mapping = []
    for key, output in mapping:
        # Uppercase the key if it is a letter
        key_upper = key.upper() if key.isalpha() else key

        # Uppercase the output if it starts with a letter
        if output and output[0].isalpha():
            if titlecase:
                output_upper = output[0].upper() + output[1:]
            else:
                output_upper = output.upper()
        else:
            output_upper = output

        uppercase_mapping.append((key_upper, output_upper))
    return uppercase_mapping


def add_action_state(
    content: str, action_id: str, state_number: int, output: str
) -> str:
    """
    Insert a new <when state="sX" output="..."/> line inside the <action id="..."> block.
    Raises a ValueError if a <when> with the same state already exists.
    """
    pattern = rf'(<action id="{re.escape(action_id)}">)(.*?)(</action>)'
    content = ensure_action_block(content, action_id, action_id)

    def repl(match):
        header, body, footer = match.groups()

        # Check if the state already exists
        if re.search(rf'state="s{state_number}"', body):
            raise ValueError(
                f'Action "{action_id}" already has state s{state_number} defined.'
            )

        new_line = f'\t<when state="s{state_number}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t\t{footer}"

    content = re.sub(pattern, repl, content, flags=re.DOTALL)
    return content


def add_terminator_state(content: str, state_number: int, output: str) -> str:
    """
    Add a <when state="sX" output="..."/> line inside the <terminators> block.
    Raises ValueError if the state already exists.
    """
    pattern = r"(<terminators>)(.*?)(</terminators>)"

    def repl(match):
        header, body, footer = match.groups()
        # Check if state already exists
        if re.search(rf'<when state="s{state_number}"', body):
            raise ValueError(
                f"State s{state_number} already exists in <terminators> block."
            )
        new_line = f'\t<when state="s{state_number}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t{footer}"

    return re.sub(pattern, repl, content, flags=re.DOTALL)


def assign_action_layer(content: str, action_id: str, layer_num: int) -> str:
    """
    Assigns a next state (layer) to a single <action id="..."> in the content.
    Modifies the default <when state="none"/> line to include a 'next' state.
    Works even if action_id is encoded as &lt; or &#x003C; in the XML.
    """
    # autoriser id="<" OU id="&lt;" OU id="&#x003C;"
    if action_id == "<":
        id_pattern = r"(?:<|&lt;|&#x003C;)"
    elif action_id == ">":
        id_pattern = r"(?:>|&gt;|&#x003E;)"
    else:
        id_pattern = re.escape(action_id)

    pattern = rf'(<action id="{id_pattern}">)(.*?)(</action>)'

    def repl(match):
        header, body, footer = match.groups()
        body = re.sub(
            r'<when state="none"[^>]*>',
            f'<when state="none" next="s{layer_num}"/>',
            body,
        )
        return f"{header}{body}{footer}"

    return re.sub(pattern, repl, content, flags=re.DOTALL)
