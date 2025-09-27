import json
import os

import yaml
from utilities.cleaning import clean_invalid_xml_chars
from xkb_creation import generate_xkb_content

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


def parse_actions_for_xcompose(keylayout_path):
    """Parse the <actions> block and write a .XCompose file, only for deadkey states (state != none), with blank lines between deadkey groups. Deadkey names are replaced by their real Unicode symbol or deadkey_<name> if found in YAML mapping."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return
    print(f"[INFO] Parsing actions from {keylayout_path}")
    with open(keylayout_path, encoding="utf-8") as file_in:
        xml_text = file_in.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    if actions is None:
        print("[WARNING] No <actions> block found.")
        return
    # Build deadkey_name -> unicode_symbol mapping
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
                # The symbol that triggers the deadkey is the output of the action with next=sX
                if action_id and deadkey_name not in deadkey_symbol:
                    deadkey_symbol[deadkey_name] = output
    # Build Compose lines
    lines = []
    # Ajout des règles de fraction vers séquence multi-caractère
    if hasattr(generate_xkb_content, "fraction_map"):
        for frac, seq in generate_xkb_content.fraction_map.items():
            left = mappings.get(frac, f"U{ord(frac):04X}")
            lines.append(f'<{left}> : "{seq}"')
    lines.append(f'<{mappings.get("«", "guillemotleft")}> : "« "')
    lines.append(f'<{mappings.get("»", "guillemotright")}> : " »"')
    lines.append("")
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
    first = True
    for deadkey in sorted(by_deadkey.keys()):
        if not first:
            lines.append("")  # blank line between deadkey groups
        first = False
        for action_id, output in sorted(by_deadkey[deadkey]):
            seq = []
            # Replace <dead_X> by its real Unicode symbol or deadkey_<name> if found in YAML
            if deadkey in deadkey_symbol:
                symbol = deadkey_symbol[deadkey]
                xkb_name = mappings.get(symbol)
                codepoint = (
                    ord(symbol[0]) if symbol and len(symbol) > 0 else None
                )
                # Table de correspondance explicite pour les deadkeys Linux standards
                deadkey_linux_map = {
                    "s1_circumflex": "dead_circumflex",
                    "s2_currency": "dead_currency",
                    "s3_diaeresis": "dead_diaeresis",
                    "s4_greek": "mu",
                    "s5_superscript": "uparrow",
                    "s6_subscript": "downarrow",
                    "s7_RR": "infinity",
                }
                if deadkey in deadkey_linux_map:
                    seq.append(f"<{deadkey_linux_map[deadkey]}>")
                elif codepoint == 0x20B0:
                    seq.append("<dead_currency>")
                elif codepoint == 0x2792 or codepoint == 0x00A8:
                    seq.append("<dead_diaeresis>")
                elif codepoint == 0x2126:
                    seq.append("<mu>")
                elif codepoint == 0x02FA:
                    seq.append("<uparrow>")
                elif codepoint == 0x02FC:
                    seq.append("<downarrow>")
                elif codepoint == 0x27E7:
                    seq.append("<infinity>")
                elif xkb_name:
                    if xkb_name == "asciicircum":
                        seq.append("<dead_circumflex>")
                    elif xkb_name == "currency":
                        seq.append("<dead_currency>")
                    elif xkb_name == "diaeresis":
                        seq.append("<dead_diaeresis>")
                    else:
                        seq.append(f"<deadkey_{xkb_name}>")
                else:
                    left = mappings.get(
                        symbol,
                        f"U{ord(symbol[0]):04X}" if symbol else "NoSymbol",
                    )
                    seq.append(f"<{left}>")
            else:
                # Utiliser le mapping YAML si possible
                deadkey_linux_map = {
                    "s1_circumflex": "dead_circumflex",
                    "s2_currency": "dead_currency",
                    "s3_diaeresis": "dead_diaeresis",
                    "s4_greek": "mu",
                    "s5_superscript": "uparrow",
                    "s6_subscript": "downarrow",
                    "s7_RR": "infinity",
                }
                if deadkey in deadkey_linux_map:
                    seq.append(f"<{deadkey_linux_map[deadkey]}>")
                else:
                    left = mappings.get(deadkey, deadkey)
                    seq.append(f"<{left}>")
            if action_id:
                # Utiliser le mapping YAML si possible pour action_id
                left_action = mappings.get(action_id, action_id)
                seq.append(f"<{left_action}>")
            # On ne garde que le caractère entre guillemets pour la sortie XCompose
            out = f'"{output}"'
            # Remplacer < > par <space> dans la séquence
            seq = ["<space>" if s == "< >" else s for s in seq]
            lines.append(f"{' '.join(seq)}\t: {out}")
    content = 'include "%L"\n\n' + "\n".join(lines) + "\n"
    return content
