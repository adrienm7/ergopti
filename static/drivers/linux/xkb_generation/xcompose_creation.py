import json
import os
from typing import Any

import yaml
from utilities.cleaning import clean_invalid_xml_chars

try:
    from lxml import etree as LET
except ImportError:
    LET = None

with open(
    os.path.join(
        os.path.dirname(__file__), "data", "linux_to_macos_keycodes.json"
    ),
    "r",
    encoding="utf-8",
) as keycodes_file:
    LINUX_TO_MACOS_KEYCODES = json.load(keycodes_file)

yaml_path = os.path.join(os.path.dirname(__file__), "data", "key_sym.yaml")
with open(yaml_path, encoding="utf-8") as yaml_file:
    mappings = yaml.safe_load(yaml_file)

deadkey_defined_names = {
    "s1_circumflex": "dead_circumflex",
    "s2_currency": "dead_currency",
    "s3_diaeresis": "dead_diaeresis",
    "s4_greek": "mu",
    "s5_superscript": "uparrow",
    "s6_subscript": "downarrow",
    "s7_RR": "infinity",
}


def generate_xcompose(
    keylayout_data: str, mapped_symbols: dict[str, str]
) -> str:
    """Parse <actions> and write a .XCompose file for deadkey states.

    Args:
        keylayout_data: XML keylayout data.
        mapped_symbols: Mapping of triggers to output symbols.

    Returns:
        The generated XCompose file content as a string.
    """
    xml_text = clean_invalid_xml_chars(keylayout_data)
    actions = parse_actions(xml_text)
    if actions is None:
        print("[WARNING] No <actions> block found.")
        return ""

    by_deadkey = build_by_deadkey(actions)
    trigger_to_id = build_trigger_to_id(actions)

    lines: list[str] = []
    for trigger, output in mapped_symbols.items():
        symbol_name = mappings.get(output, output)
        if symbol_name not in ["uparrow", "downarrow", "infinity"]:
            lines.append(f'<{symbol_name}> : "{trigger}"')
    lines.append("")

    first = True
    for deadkey in sorted(by_deadkey.keys()):
        if not first:
            lines.append("")
        first = False

        if deadkey in deadkey_defined_names:
            trigger = deadkey_defined_names[deadkey]
        else:
            trigger = trigger_to_id[deadkey]
            trigger = mappings.get(trigger, trigger)

        # Get default output from <terminators> for state = deadkey
        output = ""
        terminators = actions.getparent().find("terminators")
        if terminators is not None:
            for when in terminators.findall("when"):
                state = when.attrib.get("state")
                out = when.attrib.get("output")
                if state == deadkey and out:
                    output = out
                    break

        # Skip deadkeys with space-like triggers
        if any(char in trigger for char in [" ", " ", " "]):
            continue

        output_str = f'"{output}"' if '"' not in output else f"'{output}'"
        lines.append(f"<{trigger}>\t: {output_str}")

        for action_id, output in sorted(by_deadkey[deadkey]):
            seq: list[str] = []
            if deadkey in deadkey_defined_names:
                seq.append(f"<{deadkey_defined_names[deadkey]}>")
            elif deadkey in trigger_to_id:
                trigger = trigger_to_id[deadkey]
                if len(trigger) >= 2:
                    break
                trigger = mappings.get(trigger, trigger)
                seq.append(f"<{trigger}>")
            else:
                seq.append(f"<{deadkey}>")

            # Add key pressed after deadkey
            if action_id:
                left_action = mappings.get(action_id, action_id)
                seq.append(f"<{left_action}>")

            out_str = f'"{output}"' if '"' not in output else f"'{output}'"
            lines.append(f"{' '.join(seq)}\t: {out_str}")
    content = 'include "%L"\n\n' + "\n".join(lines) + "\n"
    return content


def parse_actions(xml_text: str) -> Any:
    """Return the <actions> block from cleaned XML text.

    Args:
        xml_text: Cleaned XML string.

    Returns:
        The <actions> XML element or None.
    """
    tree = LET.fromstring(xml_text.encode("utf-8"))
    return tree.find(".//actions")


def build_trigger_to_id(actions: Any) -> dict[str, str]:
    """Build mapping: trigger -> action id for when state=none.

    Args:
        actions: XML <actions> element.

    Returns:
        Dictionary mapping trigger to action id.
    """
    trigger_to_id: dict[str, str] = {}
    for action in actions.findall("action"):
        action_id = action.attrib.get("id")
        for when in action.findall("when"):
            state = when.attrib.get("state")
            next_state = when.attrib.get("next")
            if state == "none" and next_state:
                trigger_to_id[next_state] = action_id
    return trigger_to_id


def build_by_deadkey(actions: Any) -> dict[str, list[tuple[str, str]]]:
    """Build mapping: deadkey -> list of (action_id, output) for states != none.

    Args:
        actions: XML <actions> element.

    Returns:
        Dictionary mapping deadkey to list of (action_id, output).
    """
    by_deadkey: dict[str, list[tuple[str, str]]] = {}
    for action in actions.findall("action"):
        action_id = action.attrib.get("id")
        for when in action.findall("when"):
            state = when.attrib.get("state")
            output = when.attrib.get("output")
            if not output:
                continue
            if state and state.startswith("s") and state[1:].isdigit():
                state = f"dead_{int(state[1:])}"
            if state and state != "none":
                by_deadkey.setdefault(state, []).append((action_id, output))
    return by_deadkey
