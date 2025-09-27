import datetime
import json
import os
import re
from logging import getLogger

import yaml
from utilities.information_extraction import (
    build_deadkey_symbol_map,
    extract_deadkey_triggers,
    extract_keymap_body,
)
from xcompose_creation import parse_actions_for_xcompose
from xkb_creation import generate_xkb_content

try:
    from lxml import etree as LET
except ImportError:
    LET = None

data_dir = os.path.join(os.path.dirname(__file__), "data")
with open(
    os.path.join(data_dir, "linux_to_macos_keycodes.json"), encoding="utf-8"
) as f:
    LINUX_TO_MACOS_KEYCODES = json.load(f)
with open(os.path.join(data_dir, "key_sym.yaml"), encoding="utf-8") as f:
    mappings = yaml.safe_load(f)

logger = getLogger("ergopti.linux")


def main(keylayout_name="Ergopti_v2.2.0.keylayout", use_date_in_filename=False):
    macos_dir = get_macos_dir()
    base_prefix = os.path.splitext(keylayout_name)[0]
    variants = [base_prefix, base_prefix + "_plus"]

    for variant in variants:
        keylayout_file = variant + ".keylayout"
        keylayout_path = os.path.join(macos_dir, keylayout_file)
        logger.info("Using keylayout: %s", keylayout_path)
        keylayout_data = read_file(keylayout_path)

        xkb_template_path = os.path.join(
            os.path.dirname(__file__), "data", "base.xkb"
        )
        xkb_template = read_file(xkb_template_path)

        layout_id, layout_name = create_layout_name(
            variant, use_date_in_filename
        )
        # Remplacement du nom de la disposition et du nom affiché
        xkb_template = re.sub(
            r'xkb_symbols\s+"[^"]+"', f'xkb_symbols "{layout_id}"', xkb_template
        )
        xkb_template = re.sub(
            r'name\[Group1\]=\s+"[^"]+";',
            f'name[Group1]= "{layout_name}";',
            xkb_template,
        )

        # Extract keymaps (0, 2, 5, 6, 4, 4) from the ISO keyMapSet
        logger.info(
            "Extracting keymaps for layers 0, 2, 5, 6, 4, 4 from <keyMapSet id='ISO'>..."
        )
        keymaps = [
            extract_keymap_body(keylayout_data, i, keymapset_id="ISO")
            for i in [0, 2, 5, 6, 4]
        ]
        keymaps.append(keymaps[4])

        # Deadkey extraction
        logger.info("Building deadkey trigger map...")
        deadkey_triggers = extract_deadkey_triggers(keylayout_path)

        # deadkey_name -> unicode_symbol
        logger.info("Building deadkey symbol map...")
        deadkey_symbol = build_deadkey_symbol_map(keylayout_path)

        # XKB generation
        logger.info("Generating XKB content...")
        xkb_out_content = generate_xkb_content(
            xkb_template, keymaps, deadkey_triggers, deadkey_symbol
        )
        xkb_out_path = os.path.join(
            os.path.dirname(__file__), "..", f"{variant}.xkb"
        )
        save_file(xkb_out_path, xkb_out_content)

        # XCompose generation
        xcompose_content = parse_actions_for_xcompose(keylayout_path)
        xcompose_out_path = os.path.splitext(xkb_out_path)[0] + ".XCompose"
        save_file(xcompose_out_path, xcompose_content)


def read_file(file_path):
    logger.info("Reading input from %s", file_path)
    if not os.path.isfile(file_path):
        raise FileNotFoundError(f"File not found: {file_path}")
    with open(file_path, encoding="utf-8") as file:
        return file.read()


def save_file(file_path, content):
    logger.info("Writing output to %s", file_path)
    with open(file_path, "w", encoding="utf-8") as file:
        file.write(content)


def get_macos_dir():
    macos_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "../../macos")
    )
    if not os.path.isdir(macos_dir):
        raise FileNotFoundError(f"macos directory does not exist: {macos_dir}")
    return macos_dir


def create_layout_name(variant, use_date_in_filename):
    if use_date_in_filename:
        now = datetime.datetime.now()
        layout_id = f"{variant}_{now.year}_{now.month:02d}_{now.day:02d}_{now.hour:02d}h{now.minute:02d}"
        layout_name = f"France - {variant.replace('_', ' ').title().replace('V', 'v')} {now.year}/{now.month:02d}/{now.day:02d} {now.hour:02d}:{now.minute:02d}"
    else:
        layout_id = variant
        layout_name = "France - " + variant.replace("_", " ").title().replace(
            "V", "v"
        )
    return layout_id, layout_name


if __name__ == "__main__":
    main(use_date_in_filename=False)
