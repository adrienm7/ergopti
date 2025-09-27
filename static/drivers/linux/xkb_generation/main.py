import datetime
import json
import os
import re

import yaml
from utilities.cleaning import clean_invalid_xml_chars
from utilities.information_extraction import (
    extract_deadkey_triggers,
    extract_keymap_body,
)
from xcompose_creation import parse_actions_for_xcompose
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


def main(keylayout_name="Ergopti_v2.2.0.keylayout", use_date_in_filename=False):
    macos_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "../../macos")
    )
    if not os.path.isdir(macos_dir):
        raise FileNotFoundError(f"macos directory does not exist: {macos_dir}")

    # Déduire le préfixe de base (ex: Ergopti_v2.2.0)
    base_prefix = os.path.splitext(keylayout_name)[0]
    variants = [base_prefix, base_prefix + "_plus"]

    for variant in variants:
        keylayout_file = variant + ".keylayout"
        print(f"[INFO] Using keylayout: {keylayout_file}")
        # Lecture du keylayout et du template XKB
        print("[INFO] Reading keylayout file...")
        macos_data, keylayout_path = read_keylayout_file(
            macos_dir, keylayout_file
        )
        xkb_path = os.path.join(os.path.dirname(__file__), "data", "base.xkb")
        if not os.path.isfile(xkb_path):
            raise FileNotFoundError(f"base.xkb file not found: {xkb_path}")
        print("[INFO] Reading base.xkb template...")
        xkb_content = read_xkb_template(xkb_path)

        # Gestion du nom de layout et affichage
        if use_date_in_filename:
            now = datetime.datetime.now()
            layout_id = f"{variant}_{now.year}_{now.month:02d}_{now.day:02d}_{now.hour:02d}h{now.minute:02d}"
            layout_name = f"France - {variant.replace('_', ' ').title().replace('V', 'v')} {now.year}/{now.month:02d}/{now.day:02d} {now.hour:02d}:{now.minute:02d}"
        else:
            layout_id = variant
            # Ergopti_v2.2.0_plus -> Ergopti v2.2.0 Plus
            layout_name = "France - " + variant.replace(
                "_", " "
            ).title().replace("V", "v")

        # Remplacement du nom de la disposition et du nom affiché
        xkb_content = re.sub(
            r'xkb_symbols\s+"[^"]+"', f'xkb_symbols "{layout_id}"', xkb_content
        )
        xkb_content = re.sub(
            r'name\[Group1\]=\s*"[^"]+";',
            f'name[Group1]= "{layout_name}";',
            xkb_content,
        )

        # Extract keymaps (0, 2, 5, 6, 4, 4) from the ISO keyMapSet
        print(
            "[INFO] Extracting keymaps for layers 0, 2, 5, 6, 4, 4 from <keyMapSet id='ISO'>..."
        )
        keymaps = [
            extract_keymap_body(macos_data, i, keymapset_id="ISO")
            for i in [0, 2, 5, 6, 4]
        ]
        keymaps.append(keymaps[4])

        # Deadkey extraction
        print("[INFO] Building deadkey trigger map...")
        deadkey_triggers = extract_deadkey_triggers(keylayout_path)

        # deadkey_name -> unicode_symbol
        print("[INFO] Building deadkey symbol map...")
        deadkey_symbol = build_deadkey_symbol_map(keylayout_path)

        # XKB generation
        print("[INFO] Generating XKB content...")
        xkb_out_content = generate_xkb_content(
            xkb_content, keymaps, deadkey_triggers, deadkey_symbol
        )

        # Output files: same name as input keylayout (without extension)
        base_name = variant
        xkb_out_path = os.path.join(
            os.path.dirname(__file__), "..", f"{base_name}.xkb"
        )
        xcompose_out_path = os.path.splitext(xkb_out_path)[0] + ".XCompose"

        # Write files
        print(f"[INFO] Writing XKB output to {xkb_out_path}")
        with open(xkb_out_path, "w", encoding="utf-8") as file_out:
            file_out.write(xkb_out_content)

        print(f"[INFO] Writing XCompose output to {xcompose_out_path}")
        parse_actions_for_xcompose(keylayout_path, xcompose_out_path)


def build_deadkey_symbol_map(keylayout_path):
    """Construit la table deadkey_name -> unicode_symbol."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return {}
    with open(keylayout_path, encoding="utf-8") as file_in:
        xml_text = file_in.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    deadkey_symbol = {}
    if actions is not None:
        for action in actions.findall("action"):
            action_id = action.attrib.get("id")
            for when in action.findall("when"):
                state = when.attrib.get("state")
                output = when.attrib.get("output")
                if not output:
                    continue
                if state and state.startswith("s") and state[1:].isdigit():
                    deadkey_name = f"dead_{int(state[1:])}"
                    if action_id and action_id not in deadkey_symbol:
                        deadkey_symbol[deadkey_name] = output
    return deadkey_symbol


def unicode_repr(s):
    """Return a string as a quoted char and Uxxxx code(s) for XCompose comment."""
    if not s:
        return '""'
    return f'"{s}" ' + " ".join(f"U{ord(c):04X}" for c in s)


def read_keylayout_file(macos_dir, keylayout_name):
    """Read the keylayout file and return its content and path."""
    keylayout_path = os.path.join(macos_dir, keylayout_name)
    with open(keylayout_path, encoding="utf-8") as file_in:
        return file_in.read(), keylayout_path


def read_xkb_template(xkb_path):
    """Read the base XKB template file."""
    with open(xkb_path, encoding="utf-8") as file_in:
        return file_in.read()


if __name__ == "__main__":
    main(use_date_in_filename=False)
