import json
import os

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


def generate_xcompose(keylayout_data, mapped_symbols):
    """Parse the <actions> block and write a .XCompose file, only for deadkey states (state != none), with blank lines between deadkey groups. Deadkey names are replaced by their real Unicode symbol or deadkey_<name> if found in YAML mapping."""
    xml_text = clean_invalid_xml_chars(keylayout_data)
    actions = parse_actions(xml_text)
    if actions is None:
        print("[WARNING] No <actions> block found.")
        return
    deadkey_symbol = build_deadkey_symbol(actions)
    trigger_to_id = build_trigger_to_id(actions)
    by_deadkey = build_by_deadkey(actions)

    lines = []
    for trigger, output in mapped_symbols.items():
        symbol_name = mappings.get(output, output)
        lines.append(f'<{symbol_name}> : "{trigger}"')
    lines.append("")

    deadkey_linux_map = {
        "s1_circumflex": "dead_circumflex",
        "s2_currency": "dead_currency",
        "s3_diaeresis": "dead_diaeresis",
        "s4_greek": "mu",
        "s5_superscript": "uparrow",
        "s6_subscript": "downarrow",
        "s7_RR": "infinity",
    }
    first = True
    for deadkey in sorted(by_deadkey.keys()):
        if not first:
            lines.append("")
        first = False
        for action_id, output in sorted(by_deadkey[deadkey]):
            seq = []
            if deadkey in deadkey_linux_map:
                seq.append(f"<{deadkey_linux_map[deadkey]}>")
            else:
                left = mappings.get(deadkey, deadkey)
                seq.append(f"<{left}>")

            if action_id:
                # Add the key to be pressed after the deadkey
                left_action = mappings.get(action_id, action_id)
                seq.append(f"<{left_action}>")

            out = f'"{output}"'
            lines.append(f"{' '.join(seq)}\t: {out}")
    content = 'include "%L"\n\n' + "\n".join(lines) + "\n"
    return content


def parse_actions(xml_text):
    """Retourne la liste des actions à partir du XML nettoyé."""
    tree = LET.fromstring(xml_text.encode("utf-8"))
    return tree.find(".//actions")


def build_deadkey_symbol(actions):
    """Construit le mapping deadkey_name -> symbole unicode."""
    deadkey_symbol = {}
    for action in actions.findall("action"):
        action_id = action.attrib.get("id")
        for when in action.findall("when"):
            state = when.attrib.get("state")
            output = when.attrib.get("output")
            if not output:
                continue
            if state and state.startswith("s") and state[1:].isdigit():
                deadkey_name = f"dead_{int(state[1:])}"
                if action_id and deadkey_name not in deadkey_symbol:
                    deadkey_symbol[deadkey_name] = output
    return deadkey_symbol


def build_trigger_to_id(actions):
    """Construit le mapping trigger -> id d'action pour when state=none."""
    trigger_to_id = {}
    for action in actions.findall("action"):
        action_id = action.attrib.get("id")
        for when in action.findall("when"):
            state = when.attrib.get("state")
            next_state = when.attrib.get("next")
            if state == "none" and next_state:
                trigger_to_id[next_state] = action_id
    return trigger_to_id


def build_by_deadkey(actions):
    """Construit le mapping deadkey -> liste (action_id, output) pour les états != none."""
    by_deadkey = {}
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
