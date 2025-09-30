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

    by_deadkey = build_by_deadkey(actions)
    trigger_to_id = build_trigger_to_id(actions)

    lines = []
    for trigger, output in mapped_symbols.items():
        symbol_name = mappings.get(output, output)
        lines.append(f'<{symbol_name}> : "{trigger}"')
    lines.append("")

    deadkey_defined_names = {
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

        if deadkey in deadkey_defined_names:
            trigger = deadkey_defined_names[deadkey]
        else:
            trigger = trigger_to_id[deadkey]
            trigger = mappings.get(trigger, trigger)

        # Recherche l’output par défaut dans le bloc <terminators> pour state = deadkey
        output = ""
        terminators = actions.getparent().find("terminators")
        if terminators is not None:
            for when in terminators.findall("when"):
                state = when.attrib.get("state")
                out = when.attrib.get("output")
                if state == deadkey and out:
                    output = out
                    break

        # Don’t add deadkey like "nbsp ponctuation"
        if any(char in trigger for char in [" ", " ", " "]):
            continue

        if '"' not in output:
            output = f'"{output}"'
        else:
            output = f"'{output}'"

        lines.append(
            f"<{trigger}>\t: {output}"
        )  # Add behavior when the key pressed next isn’t defined in the deadkey (default output)

        for action_id, output in sorted(by_deadkey[deadkey]):
            seq = []
            if deadkey in deadkey_defined_names:
                seq.append(f"<{deadkey_defined_names[deadkey]}>")
            elif deadkey in trigger_to_id:
                trigger = trigger_to_id[deadkey]

                if len(trigger) >= 2:
                    # Don’t add deadkey like "nbsp ponctuation"
                    break

                trigger = mappings.get(trigger, trigger)
                seq.append(f"<{trigger}>")
            else:
                seq.append(f"<{deadkey}>")

            # Add the key to be pressed after the deadkey
            if action_id:
                left_action = mappings.get(action_id, action_id)
                seq.append(f"<{left_action}>")

            if '"' not in output:
                out = f'"{output}"'
            else:
                out = f"'{output}'"

            lines.append(f"{' '.join(seq)}\t: {out}")
    content = 'include "%L"\n\n' + "\n".join(lines) + "\n"
    return content


def parse_actions(xml_text):
    """Retourne la liste des actions à partir du XML nettoyé."""
    tree = LET.fromstring(xml_text.encode("utf-8"))
    return tree.find(".//actions")


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
