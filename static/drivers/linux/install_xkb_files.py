"""
Installs Ergopti XKB keyboard layouts on Linux systems.

This script handles the installation of .xkb files, corresponding .XCompose files,
and updates necessary system configuration files like evdev.xml and evdev.lst.
It can be run in interactive mode for guided installation or with command-line
arguments for automated setup.

Requires sudo privileges to modify system files in /usr/share/X11/xkb.
"""

import argparse
import logging
import os
import pwd
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Dict, Optional, Tuple

# --- Constants ---
XKB_BASE_DIR = Path("/usr/share/X11/xkb")
XKB_SYMBOLS_DIR = XKB_BASE_DIR / "symbols"
XKB_TYPES_DIR = XKB_BASE_DIR / "types"
XKB_RULES_DIR = XKB_BASE_DIR / "rules"

# --- Logging Configuration ---
logging.basicConfig(
    level=logging.INFO,
    format="%(levelname)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)


def check_sudo() -> None:
    """
    Exits if the script is not run with sudo privileges.

    Raises:
        SystemExit: If the effective user ID is not 0.
    """
    if os.geteuid() != 0:
        logging.error("This script must be run with sudo privileges.")
        sys.exit(1)


def backup_file(file_path: Path) -> bool:
    """
    Creates a numbered backup of a file.

    Args:
        file_path: The path to the file to back up.

    Returns:
        True if a backup was created, False otherwise.
    """
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


# --- Interactive Mode Functions ---


def select_from_menu(prompt: str, options: Dict[str, str]) -> str:
    """
    Displays a menu and returns the user's selection.

    Args:
        prompt: The message to display to the user.
        options: A dictionary mapping choice numbers to descriptions.

    Returns:
        The key corresponding to the user's choice.
    """
    print(prompt)
    for key, value in options.items():
        print(f"{key}. {value}")

    while True:
        choice = input(f"Your choice ({', '.join(options.keys())}): ").strip()
        if choice in options:
            return choice
        logging.warning("Invalid choice. Please try again.")


def find_layout_files(
    directory: Path, version: str
) -> Tuple[Optional[Path], Optional[Path], Optional[Path]]:
    """
    Finds the latest XKB, XCompose, and types files for a given version.

    Args:
        directory: The root directory to search within.
        version: The layout version ('normal', 'plus', 'plus_plus').

    Returns:
        A tuple containing paths to the XKB, XCompose, and types files, or None.
    """
    version_patterns = {
        "normal": "*ergopti_v*[0-9].xkb",
        "plus": "*ergopti_v*plus.xkb",
        "plus_plus": "*ergopti_v*plus_plus.xkb",
    }

    search_pattern = version_patterns.get(version, "")
    if not search_pattern:
        return None, None, None

    # Find all matching XKB files recursively
    xkb_files = list(directory.rglob(search_pattern))

    # Filter out incorrect matches
    if version == "normal":
        xkb_files = [f for f in xkb_files if "plus" not in f.name.lower()]
    elif version == "plus":
        xkb_files = [f for f in xkb_files if "plus_plus" not in f.name.lower()]

    if not xkb_files:
        logging.warning("No .xkb files found for version '%s'.", version)
        return None, None, None

    # Select the most recently modified XKB file
    latest_xkb = max(xkb_files, key=lambda f: f.stat().st_mtime)
    logging.info("Selected XKB file: %s", latest_xkb)

    xkb_dir = latest_xkb.parent
    xkb_basename = latest_xkb.stem

    # Find corresponding XCompose and types files
    xcompose_file = xkb_dir / f"{xkb_basename}.XCompose"
    if not xcompose_file.exists():
        logging.warning("No corresponding .XCompose file found.")
        xcompose_file = None

    types_choice = select_from_menu(
        "Select the types file to use:",
        {
            "1": "Default types (xkb_types.txt)",
            "2": "Types without Ctrl mappings (xkb_types_without_ctrl.txt)",
        },
    )
    types_filename = (
        "xkb_types.txt" if types_choice == "1" else "xkb_types_without_ctrl.txt"
    )
    types_file = xkb_dir / types_filename
    if not types_file.exists():
        logging.warning("Could not find '%s' in %s.", types_filename, xkb_dir)
        return latest_xkb, xcompose_file, None

    return latest_xkb, xcompose_file, types_file


# --- File Content Extraction and Manipulation ---


def extract_xkb_info(xkb_file: Path) -> Tuple[str, str]:
    """
    Extracts the layout's symbol name and display name from an .xkb file.

    Args:
        xkb_file: Path to the .xkb file.

    Returns:
        A tuple containing the symbol name and the display name.
    """
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
    """
    Updates the evdev.lst file with the new layout variant.

    Args:
        lst_path: Path to the evdev.lst file.
        symbol_name: The symbol name of the layout (e.g., 'ergopti_v2_2_0').
        display_name: The human-readable name of the layout.
    """
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
    """
    Updates the evdev.xml file to include the new layout variant.

    Args:
        xml_path: Path to the evdev.xml file.
        symbol_name: The symbol name of the layout.
        display_name: The human-readable name of the layout.
    """
    if not xml_path.exists():
        logging.error("XML file not found: %s", xml_path)
        return

    try:
        ET.register_namespace("", "http://www.freedesktop.org/xkb/xconfig")
        tree = ET.parse(str(xml_path))
        root = tree.getroot()

        fr_layout = root.find(".//layout[configItem/name='fr']")
        if fr_layout is None:
            logging.error("French layout section not found in %s.", xml_path)
            return

        variant_list = fr_layout.find("variantList")
        if variant_list is None:
            variant_list = ET.SubElement(fr_layout, "variantList")

        existing_variant = variant_list.find(
            f"variant[configItem/name='{symbol_name}']"
        )

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
    """
    Appends or replaces the layout definition in the system's 'fr' symbols file.

    Args:
        source_xkb: The path to the source .xkb file.
        symbol_name: The symbol name of the layout to update.
        dest_symbols_file: The path to the system's 'fr' symbols file.
    """
    try:
        with source_xkb.open("r", encoding="utf-8") as f:
            source_content = f.read()

        section_match = re.search(
            rf'xkb_symbols "{symbol_name}" \{{.*?^\}};',
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

            # Use regex to find and replace the whole block
            pattern = re.compile(
                rf'xkb_symbols "{symbol_name}" \{{.*?^\}};',
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
    """
    Appends or replaces type definitions in the system's 'extra' types file.

    Args:
        source_types: The path to the file with type definitions.
        dest_types_file: The path to the system's 'extra' types file.
    """
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
                    f'type "{re.escape(type_name)}"' + r" \{.*?};", re.DOTALL
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
    """
    Installs the .XCompose file to the user's home directory.

    Args:
        xcompose_file: Path to the .XCompose file.
    """
    sudo_user = os.getenv("SUDO_USER")
    if not sudo_user:
        logging.error(
            "SUDO_USER environment variable not set. Cannot determine home directory."
        )
        return

    try:
        user_info = pwd.getpwnam(sudo_user)
        home_dir = Path(user_info.pw_dir)
        dest_xcompose = home_dir / ".XCompose"

        if dest_xcompose.exists():
            choice = input(
                f"{dest_xcompose} already exists. Overwrite? (y/N): "
            ).lower()
            if choice != "y":
                logging.info("Skipping .XCompose installation.")
                return

        shutil.copy(xcompose_file, dest_xcompose)
        os.chown(dest_xcompose, user_info.pw_uid, user_info.pw_gid)
        logging.info("Installed .XCompose file to %s", dest_xcompose)

    except (KeyError, OSError) as e:
        logging.error("Failed to install .XCompose file: %s", e)


# --- Main Execution ---


def parse_arguments() -> argparse.Namespace:
    """
    Parses command-line arguments.

    Returns:
        An object containing the parsed arguments.
    """
    parser = argparse.ArgumentParser(
        description="Install Ergopti XKB layout on Linux.",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("--xkb", type=Path, help="Path to the .xkb file.")
    parser.add_argument(
        "--xcompose", type=Path, help="Path to the .XCompose file."
    )
    parser.add_argument(
        "--types", type=Path, help="Path to the xkb_types.txt file."
    )
    return parser.parse_args()


def main() -> None:
    """
    Main function to run the installation script.
    """
    if sys.platform == "win32":
        logging.error("This script is for Linux and cannot be run on Windows.")
        sys.exit(1)

    check_sudo()
    args = parse_arguments()

    xkb_file, xcompose_file, types_file = args.xkb, args.xcompose, args.types

    if not xkb_file:
        # --- Interactive Mode ---
        logging.info("Entering interactive installation mode...")
        script_dir = Path(__file__).parent
        version_choice = select_from_menu(
            "Select the Ergopti version to install:",
            {
                "1": "Ergopti (normal)",
                "2": "Ergopti+ (plus)",
                "3": "Ergopti++ (plus plus)",
            },
        )
        version_map = {"1": "normal", "2": "plus", "3": "plus_plus"}
        version = version_map[version_choice]

        xkb_file, xcompose_file, types_file = find_layout_files(
            script_dir, version
        )

    # --- Validation and Installation ---
    if not xkb_file or not xkb_file.is_file():
        logging.error("XKB file not found or specified. Aborting.")
        sys.exit(1)

    symbol_name, display_name = extract_xkb_info(xkb_file)
    if not symbol_name or not display_name:
        logging.error(
            "Could not extract layout info from %s. Aborting.", xkb_file
        )
        sys.exit(1)

    # Update system files
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

    logging.info(
        "\nInstallation complete. You may need to restart your session for changes to take effect."
    )
    logging.info(
        "To activate the layout, run: setxkbmap fr -variant %s", symbol_name
    )


if __name__ == "__main__":
    main()
