"""
Non-interactive installer for Ergopti XKB files.

This script performs the actual installation steps without interactive
prompts. It expects absolute paths for the source .xkb, .XCompose and
types files and will update system files under /usr/share/X11/xkb.

It must be run with sudo privileges.
"""

import logging
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Optional, Tuple

# --- Constants ---
XKB_BASE_DIR = Path("/usr/share/X11/xkb")
XKB_SYMBOLS_DIR = XKB_BASE_DIR / "symbols"
XKB_TYPES_DIR = XKB_BASE_DIR / "types"
XKB_RULES_DIR = XKB_BASE_DIR / "rules"

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


def check_sudo() -> None:
    """Ensure the process is running with root privileges on Unix.

    On non-Unix systems the check is skipped to avoid import/module
    attribute errors during static analysis on Windows.
    """
    geteuid = getattr(os, "geteuid", None)
    if callable(geteuid):
        if geteuid() != 0:
            logging.error("This script must be run with sudo privileges.")
            sys.exit(1)
    else:
        logging.debug("Skipping geteuid check on this platform.")


def backup_file(file_path: Path) -> bool:
    if not file_path.exists():
        return False

    version = 1
    while True:
        backup_path = file_path.with_suffix(f"{file_path.suffix}.{version}")
        if not backup_path.exists():
            try:
                shutil.copy(file_path, backup_path)
                logging.info("Created backup: %s", backup_path)
                return True
            except OSError as e:
                logging.error(
                    "Failed to create backup for %s: %s", file_path, e
                )
                return False
        version += 1


def extract_xkb_info(xkb_file: Path) -> Tuple[str, str]:
    symbol_name, display_name = "", ""
    try:
        with xkb_file.open("r", encoding="utf-8") as f:
            for line in f:
                if "xkb_symbols" in line:
                    symbol_name = line.split('"')[1]
                if "name[Group1]" in line:
                    display_name = line.split('"')[1]
                if symbol_name and display_name:
                    break
    except IOError as e:
        logging.error("Could not read from %s: %s", xkb_file, e)
    return symbol_name, display_name


def update_lst_file(
    lst_path: Path, symbol_name: str, display_name: str
) -> None:
    if not lst_path.exists():
        logging.error("LST file not found: %s", lst_path)
        return

    try:
        with lst_path.open("r", encoding="utf-8") as f:
            lines = f.readlines()

        variant_section_index = -1
        for i, line in enumerate(lines):
            if line.strip() == "! variant":
                variant_section_index = i
                break

        if variant_section_index == -1:
            logging.error("Could not find '! variant' section in %s.", lst_path)
            return

        new_line = f"  {symbol_name:<15} fr: {display_name}\n"
        line_exists = any(symbol_name in line for line in lines)

        backup_file(lst_path)

        if line_exists:
            for i, line in enumerate(lines):
                if symbol_name in line:
                    lines[i] = new_line
                    logging.info("Updated variant in %s.", lst_path)
                    break
        else:
            lines.insert(variant_section_index + 1, new_line)
            logging.info("Added new variant to %s.", lst_path)

        with lst_path.open("w", encoding="utf-8") as f:
            f.writelines(lines)

    except IOError as e:
        logging.error("Failed to update %s: %s", lst_path, e)


def update_xml_file(
    xml_path: Path, symbol_name: str, display_name: str
) -> None:
    if not xml_path.exists():
        logging.error("XML file not found: %s", xml_path)
        return

    try:
        ET.register_namespace("", "http://www.freedesktop.org/xkb/xconfig")
        tree = ET.parse(str(xml_path))
        root = tree.getroot()

        fr_layout = None
        for layout in root.findall(".//layout"):
            ci = layout.find("configItem")
            if ci is None:
                continue
            name_elem = ci.find("name")
            if name_elem is not None and name_elem.text == "fr":
                fr_layout = layout
                break

        if fr_layout is None:
            logging.error("French layout section not found in %s.", xml_path)
            return

        variant_list = fr_layout.find("variantList")
        if variant_list is None:
            variant_list = ET.SubElement(fr_layout, "variantList")

        existing_variant = None
        for variant in variant_list.findall("variant"):
            ci = variant.find("configItem")
            if ci is None:
                continue
            name_elem = ci.find("name")
            if name_elem is not None and name_elem.text == symbol_name:
                existing_variant = variant
                break

        backup_file(xml_path)

        if existing_variant is not None:
            desc = existing_variant.find("configItem/description")
            if desc is not None:
                desc.text = display_name
                logging.info(
                    "Updated variant '%s' in %s.", symbol_name, xml_path
                )
        else:
            new_variant = ET.Element("variant")
            config_item = ET.SubElement(new_variant, "configItem")
            ET.SubElement(config_item, "name").text = symbol_name
            ET.SubElement(config_item, "description").text = display_name
            variant_list.insert(0, new_variant)
            logging.info("Added new variant '%s' to %s.", symbol_name, xml_path)

        tree.write(
            str(xml_path),
            encoding="utf-8",
            xml_declaration=True,
            short_empty_elements=False,
        )

    except (ET.ParseError, IOError) as e:
        logging.error("Failed to update %s: %s", xml_path, e)


def update_xkb_symbols_file(
    source_xkb: Path, symbol_name: str, dest_symbols_file: Path
) -> None:
    try:
        with source_xkb.open("r", encoding="utf-8") as f:
            source_content = f.read()

        section_match = re.search(
            rf'xkb_symbols "{re.escape(symbol_name)}" \{{.*?^\}};',
            source_content,
            re.DOTALL | re.MULTILINE,
        )
        if not section_match:
            logging.error("Could not find symbol section in %s.", source_xkb)
            return
        section_to_add = section_match.group(0)

        if not dest_symbols_file.exists():
            logging.info(
                "System symbols file %s not found. Creating it.",
                dest_symbols_file,
            )
            dest_symbols_file.touch()

        with dest_symbols_file.open("r+", encoding="utf-8") as f:
            content = f.read()
            backup_file(dest_symbols_file)

            pattern = re.compile(
                rf'xkb_symbols "{re.escape(symbol_name)}" \{{.*?^\}};',
                re.DOTALL | re.MULTILINE,
            )
            if pattern.search(content):
                new_content = pattern.sub(section_to_add, content)
                logging.info(
                    "Replaced existing symbols section in %s.",
                    dest_symbols_file,
                )
            else:
                new_content = content.rstrip() + "\n\n" + section_to_add + "\n"
                logging.info(
                    "Appended new symbols section to %s.", dest_symbols_file
                )

            f.seek(0)
            f.write(new_content)
            f.truncate()

    except (IOError, re.error) as e:
        logging.error(
            "Failed to update symbols file %s: %s", dest_symbols_file, e
        )


def update_xkb_types_file(source_types: Path, dest_types_file: Path) -> None:
    try:
        with source_types.open("r", encoding="utf-8") as f:
            source_content = f.read()

        type_sections = re.findall(
            r'type ".*?" \{.*?\};', source_content, re.DOTALL
        )
        if not type_sections:
            logging.warning("No type sections found in %s.", source_types)
            return

        if not dest_types_file.exists():
            logging.info(
                "System types file %s not found. Creating it.", dest_types_file
            )
            dest_types_file.touch()

        with dest_types_file.open("r+", encoding="utf-8") as f:
            content = f.read()
            backup_file(dest_types_file)
            new_content = content

            for section in type_sections:
                type_name_match = re.search(r'type "(.*?)"', section)
                if not type_name_match:
                    continue
                type_name = type_name_match.group(1)

                pattern = re.compile(
                    f'type "{re.escape(type_name)}"' + r" \{.*?\};", re.DOTALL
                )
                if pattern.search(new_content):
                    new_content = pattern.sub(section, new_content)
                    logging.info(
                        "Replaced type '%s' in %s.", type_name, dest_types_file
                    )
                else:
                    new_content = new_content.rstrip() + "\n\n" + section + "\n"
                    logging.info(
                        "Appended type '%s' to %s.", type_name, dest_types_file
                    )

            f.seek(0)
            f.write(new_content)
            f.truncate()

    except (IOError, re.error) as e:
        logging.error("Failed to update types file %s: %s", dest_types_file, e)


def install_xcompose_file(xcompose_file: Path) -> None:
    sudo_user = os.getenv("SUDO_USER")
    if not sudo_user:
        logging.error(
            "SUDO_USER environment variable not set. Cannot determine home directory."
        )
        return

    try:
        # Import pwd at runtime to avoid import errors on non-Unix platforms
        import pwd as _pwd  # type: ignore

        user_info = _pwd.getpwnam(sudo_user)
        home_dir = Path(user_info.pw_dir)
        dest_xcompose = home_dir / ".XCompose"

        shutil.copy(xcompose_file, dest_xcompose)
        chown = getattr(os, "chown", None)
        if callable(chown):
            chown(dest_xcompose, user_info.pw_uid, user_info.pw_gid)
        logging.info("Installed .XCompose file to %s", dest_xcompose)

    except (KeyError, OSError) as e:
        logging.error("Failed to install .XCompose file: %s", e)


def perform_install(
    xkb_file: Path, xcompose_file: Optional[Path], types_file: Optional[Path]
) -> None:
    symbol_name, display_name = extract_xkb_info(xkb_file)
    if not symbol_name or not display_name:
        logging.error(
            "Could not extract layout info from %s. Aborting.", xkb_file
        )
        sys.exit(1)

    update_xkb_symbols_file(xkb_file, symbol_name, XKB_SYMBOLS_DIR / "fr")

    if types_file and types_file.is_file():
        update_xkb_types_file(types_file, XKB_TYPES_DIR / "extra")
    else:
        logging.warning(
            "No types file provided or found. Skipping types update."
        )

    update_lst_file(XKB_RULES_DIR / "evdev.lst", symbol_name, display_name)
    update_xml_file(XKB_RULES_DIR / "evdev.xml", symbol_name, display_name)

    if xcompose_file and xcompose_file.is_file():
        install_xcompose_file(xcompose_file)
    else:
        logging.info("No .XCompose file specified. Skipping.")


def parse_args() -> dict:
    import argparse

    parser = argparse.ArgumentParser(
        description="Apply Ergopti XKB installation (non-interactive)."
    )
    parser.add_argument(
        "--xkb", type=Path, required=True, help="Path to the .xkb file."
    )
    parser.add_argument(
        "--xcompose", type=Path, help="Path to the .XCompose file."
    )
    parser.add_argument(
        "--types", type=Path, help="Path to the xkb_types.txt file."
    )
    return vars(parser.parse_args())


def main() -> None:
    if sys.platform == "win32":
        logging.error("This script is for Linux and cannot be run on Windows.")
        sys.exit(1)

    check_sudo()
    args = parse_args()
    perform_install(args["xkb"], args.get("xcompose"), args.get("types"))


if __name__ == "__main__":
    main()
