import argparse
import glob
import os
import pwd
import shutil
import sys
import xml.etree.ElementTree as ET

xkb_folder = "/usr/share/X11/xkb"


def check_sudo():
    """Check if the script is run with sudo privileges."""
    if os.getuid() != 0:
        print("This script must be run with sudo.")
        sys.exit(1)


def show_help():
    """Display help information."""
    print(
        "Usage: install_xkb.py [--xkb <xkb_file>] [--xcompose <xcompose_file>] [--types <types_file>]"
    )
    print(
        "This script installs a specified XKB file and updates the corresponding LST and XML files."
    )
    print()
    print(
        "Interactive mode: run the script without arguments to select a version."
    )
    print()
    print("Arguments:")
    print("  --xkb FILE       Path to the .xkb file.")
    print("  --xcompose FILE  Optional. Path to the .XCompose file.")
    print(
        "  --types FILE     Optional. Path to the xkb_types.txt or xkb_types_without_ctrl.txt file."
    )
    print("  -h, --help       Show this help message and exit.")


def select_version():
    """Let user select between normal, plus, or plus_plus version."""
    print("Select the Ergopti version to install:")
    print("1. Ergopti (normal version)")
    print("2. Ergopti+ (plus version)")
    print("3. Ergopti++ (plus plus version)")

    while True:
        choice = input("Your choice (1, 2, or 3): ").strip()
        if choice == "1":
            return "normal"
        elif choice == "2":
            return "plus"
        elif choice == "3":
            return "plus_plus"
        else:
            print("Invalid choice. Please enter 1, 2, or 3.")


def select_types_file(directory, xkb_basename):
    """Let user select the types file to use."""
    print("Select the types file to use:")
    print("1. Default types (xkb_types.txt)")
    print("2. Types without Ctrl mappings (xkb_types_without_ctrl.txt)")

    while True:
        choice = input("Your choice (1 or 2): ").strip()
        if choice == "1":
            filename = "xkb_types.txt"
        elif choice == "2":
            filename = "xkb_types_without_ctrl.txt"
        else:
            print("Invalid choice. Please enter 1 or 2.")
            continue

        # Look for the types file in the same directory as the xkb file
        types_file = os.path.join(os.path.dirname(xkb_basename), filename)
        if os.path.exists(types_file):
            return types_file

        # Fallback to searching in the script's directory and subdirectories
        for root, _, files in os.walk(directory):
            if filename in files:
                return os.path.join(root, filename)

        print(
            f"Could not find {filename}. Please check the directory structure."
        )


def find_xkb_files_by_version(directory, version):
    """Find XKB files matching the specified version."""
    patterns = {
        "normal": ["*Ergopti_v*[0-9].xkb", "*ergopti_v*[0-9].xkb"],
        "plus": ["*Ergopti_v*plus.xkb", "*ergopti_v*plus.xkb"],
        "plus_plus": ["*Ergopti_v*plus_plus.xkb", "*ergopti_v*plus_plus.xkb"],
    }

    import glob

    files = []
    for pattern in patterns.get(version, []):
        files.extend(glob.glob(os.path.join(directory, pattern)))

    # Filter out files that don't match the exact version
    if version == "normal":
        files = [f for f in files if "plus" not in os.path.basename(f).lower()]
    elif version == "plus":
        files = [
            f
            for f in files
            if "plus" in os.path.basename(f).lower()
            and "plus_plus" not in os.path.basename(f).lower()
        ]

    return files


def file_exists(file_path):
    return os.path.exists(file_path)


def backup_file(file_path):
    """Backup the specified file."""
    if os.path.exists(file_path):
        version = 1
        backup_path = f"{file_path}.{version}"
        while os.path.exists(backup_path):
            version += 1
            backup_path = f"{file_path}.{version}"
        shutil.copy(file_path, backup_path)
        return True
    return False


def install_file(source, destination_dir):
    """
    Copy the source file to the destination directory if it doesn't already exist.

    :param source: Path to the source file
    :param destination_dir: Directory where the file should be copied
    """
    file_name = os.path.basename(source)
    destination_file = os.path.join(destination_dir, file_name)

    if os.path.isfile(destination_file):
        print(f"XKB file is already installed: {destination_file}")
    else:
        shutil.copy(source, destination_file)
        print(f"XKB file copied successfully: {destination_file}")


def prettify_xml(element, indent="  ", level=0):
    """
    Prettify and indent XML element.

    :param element: XML element to be prettified.
    :param indent: Indentation string (default is two spaces).
    :param level: Current level of indentation.
    """
    if len(element):  # checks if element has children
        if not element.text or not element.text.strip():
            element.text = "\n" + indent * (level + 1)
        if not element.tail or not element.tail.strip():
            element.tail = "\n" + indent * level
        for elem in element:
            prettify_xml(elem, indent, level + 1)
        if not element[-1].tail or not element[-1].tail.strip():
            element[-1].tail = "\n" + indent * level
    else:
        if level and (not element.tail or not element.tail.strip()):
            element.tail = "\n" + indent * level
    return element


def update_xml(file_path, symbols_line, name_line):
    """Update the XML file by inserting or replacing a variant element."""
    if not file_exists(file_path):
        print(f"File not found: {file_path}")
        return
    tree = ET.parse(file_path)
    root = tree.getroot()
    for layout in root.findall(".//layout"):
        name = layout.find("./configItem/name")
        if name is not None and name.text == "fr":
            variant_list = layout.find("variantList")
            if variant_list is not None:
                # Search if the variant already exists
                existing_variant = None
                for variant in variant_list.findall("variant"):
                    config_item = variant.find("./configItem")
                    if config_item is not None:
                        name_elem = config_item.find("name")
                        if (
                            name_elem is not None
                            and name_elem.text == symbols_line
                        ):
                            existing_variant = variant
                            break
                backup_file(file_path)
                if existing_variant is not None:
                    # Replace existing variant
                    config_item = existing_variant.find("configItem")
                    name_elem = config_item.find("name")
                    description_elem = config_item.find("description")
                    name_elem.text = symbols_line
                    description_elem.text = name_line
                    print(f"Variant '{symbols_line}' updated in XML file.")
                else:
                    # Add new variant
                    new_variant = ET.Element("variant")
                    config_item = ET.SubElement(new_variant, "configItem")
                    name_elem = ET.SubElement(config_item, "name")
                    description_elem = ET.SubElement(config_item, "description")
                    name_elem.text = symbols_line
                    description_elem.text = name_line
                    variant_list.insert(0, new_variant)
                    print(f"Variant '{symbols_line}' added to XML file.")
                root = prettify_xml(root)
                tree.write(file_path, encoding="utf-8", xml_declaration=True)
                return
    print("Layout element with 'name=fr' not found.")


def update_lst(file_path, symbols_line, name_line):
    """Update the LST file by inserting or replacing the line under the '! variant' section."""
    if not file_exists(file_path):
        print(f"File not found: {file_path}")
        return
    with open(file_path, "r") as file:
        lines = file.readlines()
    variant_section_found = False
    symbols_line_exists = False
    symbols_line_index = -1
    for i, line in enumerate(lines):
        if line.startswith("! variant"):
            variant_section_found = True
            continue
        if (
            variant_section_found
            and line.strip()
            and line.split()
            and symbols_line in line.split()[0]
        ):
            symbols_line_exists = True
            symbols_line_index = i
            break
    if not variant_section_found:
        print("Section '! variant' not found in LST file.")
        return
    backup_file(file_path)
    if symbols_line_exists:
        # Replace existing line
        lst_line = f"  {symbols_line:<15} fr: {name_line}\n"
        lines[symbols_line_index] = lst_line
    else:
        # Add new line under '! variant' section
        for i, line in enumerate(lines):
            if line.startswith("! variant"):
                lst_line = f"  {symbols_line:<15} fr: {name_line}\n"
                lines.insert(i + 1, lst_line)
                break
    with open(file_path, "w") as file:
        file.writelines(lines)
    print("LST file updated successfully.")


def validate_file(file_path, extension):
    """Check if the file exists and has the correct extension."""
    if not os.path.isfile(file_path):
        print(f"File {file_path} does not exist.")
        return False
    if not file_path.endswith(extension):
        print(f"The extension of {file_path} must be {extension}")
        return False
    return True


def extract_xkb_info(xkb_file):
    """
    Extract symbols_line and name_line from the XKB file.

    :param xkb_file: Path to the XKB file
    :return: A tuple containing symbols_line and name_line
    """
    symbols_line = ""
    name_line = ""
    with open(xkb_file, "r") as file:
        for line in file:
            if "xkb_symbols" in line:
                symbols_line = line.split('"')[1]
            if "name[Group1]" in line:
                name_line = line.split('"')[1]

    return symbols_line, name_line


def install_xcompose(xcompose_file):
    """
    Install the XCompose file to the user's home directory.

    :param xcompose_file: Path to the XCompose file
    """
    if not validate_file(xcompose_file, ".XCompose"):
        return

    # Get the username of the user who invoked sudo
    username = os.getenv("SUDO_USER")
    if not username:
        print("Could not get username for XCompose installation.")
        return

    # Get the home directory of the user
    home_dir = os.path.expanduser(f"~{username}")
    xcompose_destination_file = os.path.join(home_dir, ".XCompose")

    if os.path.exists(xcompose_destination_file):
        user_choice = (
            input(
                "XCompose file already exists. Do you want to overwrite it? (Yes/No) "
            )
            .strip()
            .lower()
        )
        if user_choice not in ["yes", "y"]:
            print("XCompose installation cancelled.")
            return

    # Copy the XCompose file to the user's home directory
    shutil.copy(xcompose_file, xcompose_destination_file)
    print(f"XCompose file copied successfully: {xcompose_destination_file}")

    # Get the user ID and group ID
    uid = pwd.getpwnam(username).pw_uid
    gid = pwd.getpwnam(username).pw_gid

    # Change file ownership to the user
    if hasattr(os, "chown"):
        try:
            os.chown(xcompose_destination_file, uid, gid)
            print(f"XCompose file permissions updated for user '{username}'.")
        except Exception as e:
            print(f"Error during chown: {e}")
    else:
        print("os.chown is not available on this platform (Windows).")


def update_xkb_symbols(source_file, symbols_line, system_file):
    """
    Copy a specific section from the XKB file to the end of a system file.
    Improved to better handle existing sections.

    :param source_file: Path to the source XKB file.
    :param symbols_line: The key of the section to be copied (e.g., "optimot_ergo").
    :param system_file: Path to the system file where the section should be appended.
    """
    if not file_exists(system_file):
        print(f"File not found: {system_file}")
        return

    # Get the section to copy from the source file
    with open(source_file, "r") as file:
        lines = file.readlines()

    section_found = False
    section_lines = []
    brace_level = 0

    for i, line in enumerate(lines):
        if f'xkb_symbols "{symbols_line}"' in line and "{" in line:
            section_found = True
            brace_level = 0

        if section_found:
            section_lines.append(line)
            brace_level += line.count("{")
            brace_level -= line.count("}")

            # Check if the section ends (look for '};')
            if brace_level == 0 and line.strip().endswith("};"):
                break

    if not section_found or brace_level != 0:
        print(
            f"Section for '{symbols_line}' not found or incomplete in {source_file}."
        )
        return

    # Read the system file to see if the section already exists
    with open(system_file, "r") as file:
        system_lines = file.readlines()

    # More robust search for the existing section
    existing_start_idx = None
    existing_end_idx = None

    for i, line in enumerate(system_lines):
        if f'xkb_symbols "{symbols_line}"' in line and "{" in line:
            existing_start_idx = i
            brace_level = 0
            for j in range(i, len(system_lines)):
                brace_level += system_lines[j].count("{")
                brace_level -= system_lines[j].count("}")
                if brace_level == 0 and system_lines[j].strip().endswith("};"):
                    existing_end_idx = j
                    break
            break

    backup_file(system_file)

    if existing_start_idx is not None and existing_end_idx is not None:
        # Replace the existing section
        print(
            f"Section '{symbols_line}' found at lines {existing_start_idx + 1}-{existing_end_idx + 1}, replacing..."
        )
        system_lines[existing_start_idx : existing_end_idx + 1] = section_lines
        with open(system_file, "w") as file:
            file.writelines(system_lines)
        print(f"Section '{symbols_line}' updated successfully in {system_file}")
    else:
        # Add the section to the end if it doesn't exist
        print(
            f"Section '{symbols_line}' not found, appending to the end of the file..."
        )
        with open(system_file, "a") as file:
            file.write("\n")  # Ensure newline before new section
            file.writelines(section_lines)
        print(f"Section '{symbols_line}' added successfully to {system_file}")


def update_xkb_types(types_file, system_file):
    """
    Copy xkb_types sections from the types file and insert them into the system file.
    :param types_file: Path to the source types file (e.g., xkb_types.txt).
    :param system_file: Path to the system file where the section should be inserted.
    """
    if not file_exists(types_file):
        print(f"Types file not found: {types_file}")
        return
    if not file_exists(system_file):
        print(f"System file not found: {system_file}")
        return

    try:
        with open(types_file, "r") as file:
            source_lines = file.readlines()

        # Automatically discover types to copy
        sections_to_copy = []
        collected_sections = {}
        current_section = None
        brace_level = 0

        for line in source_lines:
            if line.strip().startswith('type "') and "{" in line:
                current_section = line.split('type "')[1].split('"')[0]
                sections_to_copy.append(current_section)
                collected_sections[current_section] = [line]
                brace_level = line.count("{") - line.count("}")
                continue

            if current_section:
                collected_sections[current_section].append(line)
                brace_level += line.count("{")
                brace_level -= line.count("}")
                if brace_level == 0:
                    current_section = None

        with open(system_file, "r") as file:
            system_lines = file.readlines()

        backup_file(system_file)

        # Check and replace existing sections
        sections_replaced = set()
        i = 0
        new_system_lines = []
        while i < len(system_lines):
            line = system_lines[i]

            section_found = None
            for section in sections_to_copy:
                if f'type "{section}"' in line and "{" in line:
                    section_found = section
                    break

            if section_found:
                # Find the end of this section
                brace_level = 0
                end_idx = -1
                for j in range(i, len(system_lines)):
                    brace_level += system_lines[j].count("{")
                    brace_level -= system_lines[j].count("}")
                    if brace_level == 0:
                        end_idx = j
                        break

                if end_idx != -1:
                    # Replace the existing section
                    new_system_lines.extend(collected_sections[section_found])
                    sections_replaced.add(section_found)
                    print(
                        f"Section '{section_found}' replaced successfully in {system_file}"
                    )
                    i = end_idx + 1
                    continue

            new_system_lines.append(line)
            i += 1

        system_lines = new_system_lines

        # Insert sections that did not exist
        sections_to_insert = [
            s for s in sections_to_copy if s not in sections_replaced
        ]

        if sections_to_insert:
            insertion_point = None
            for i, line in enumerate(system_lines):
                if 'default partial xkb_types "default"' in line:
                    brace_level = 0
                    for j in range(i, len(system_lines)):
                        brace_level += system_lines[j].count("{")
                        brace_level -= system_lines[j].count("}")
                        if brace_level == 0:
                            insertion_point = j
                            break
                    break

            if insertion_point is not None:
                # Insert new sections before the closing brace
                for section in sections_to_insert:
                    if collected_sections[section]:
                        system_lines.insert(
                            insertion_point,
                            "".join(collected_sections[section]) + "\n",
                        )
                print(f"New sections inserted successfully into {system_file}")
            else:
                print(f"Target section 'default' not found in {system_file}.")

        # Write the modified file
        with open(system_file, "w") as file:
            file.writelines(system_lines)

        if sections_replaced:
            print(f"Total of {len(sections_replaced)} section(s) replaced.")
        if sections_to_insert:
            print(f"Total of {len(sections_to_insert)} section(s) inserted.")

    except IOError as e:
        print(f"Error during file read/write: {e}")


def main():
    check_sudo()

    parser = argparse.ArgumentParser(
        description="Install XKB layout.", add_help=False
    )
    parser.add_argument("--xkb", help="Path to the .xkb file.")
    parser.add_argument("--xcompose", help="Path to the .XCompose file.")
    parser.add_argument(
        "--types", help="Path to the types file (e.g., xkb_types.txt)."
    )
    parser.add_argument(
        "-h", "--help", action="store_true", help="Show help message."
    )

    args = parser.parse_args()

    if args.help:
        show_help()
        return

    xkb_file = args.xkb
    xcompose_file = args.xcompose
    types_file = args.types

    # Interactive mode if no xkb file is provided
    if not xkb_file:
        print("Interactive mode: selecting Ergopti version to install...")
        script_dir = os.path.dirname(__file__)
        version = select_version()

        # Find files based on version
        xkb_files = find_xkb_files_by_version(script_dir, version)
        if not xkb_files:
            print(f"No .xkb file found for version {version}.")
            print("Searching in subdirectories...")
            for subdir in os.listdir(script_dir):
                subdir_path = os.path.join(script_dir, subdir)
                if os.path.isdir(subdir_path):
                    xkb_files.extend(
                        find_xkb_files_by_version(subdir_path, version)
                    )

        if not xkb_files:
            print(f"No .xkb file found for version {version}.")
            sys.exit(1)

        xkb_file = max(xkb_files, key=os.path.getmtime)
        print(f"Selected XKB file: {xkb_file}")

        # Find corresponding XCompose file
        xkb_basename = os.path.basename(xkb_file).replace(".xkb", "")

        # Search for XCompose file in the same directory as the XKB file
        potential_xcompose = os.path.join(
            os.path.dirname(xkb_file), f"{xkb_basename}.XCompose"
        )
        if os.path.exists(potential_xcompose):
            xcompose_file = potential_xcompose
        else:
            # Fallback to searching anywhere
            xcompose_files = glob.glob(
                os.path.join(script_dir, "**", "*.XCompose"), recursive=True
            )
            for xc_file in xcompose_files:
                if xkb_basename in os.path.basename(xc_file):
                    xcompose_file = xc_file
                    break

        if xcompose_file:
            print(f"Found XCompose file: {xcompose_file}")

        # Select types file
        if not types_file:
            types_file = select_types_file(script_dir, xkb_file)
            if types_file:
                print(f"Selected types file: {types_file}")

    if not xkb_file or not validate_file(xkb_file, ".xkb"):
        sys.exit(1)

    # Extract necessary info from the XKB file
    symbols_line, name_line = extract_xkb_info(xkb_file)

    # Update XKB symbols
    xkb_symbols_file = f"{xkb_folder}/symbols/fr"
    update_xkb_symbols(xkb_file, symbols_line, xkb_symbols_file)

    # Update XKB types if a types file is available
    if types_file:
        xkb_types_file = f"{xkb_folder}/types/extra"
        update_xkb_types(types_file, xkb_types_file)
    else:
        print("No types file specified, skipping types update.")

    # Update LST file
    lst_file = f"{xkb_folder}/rules/evdev.lst"
    update_lst(lst_file, symbols_line, name_line)

    # Update XML file
    xml_file = f"{xkb_folder}/rules/evdev.xml"
    update_xml(xml_file, symbols_line, name_line)

    # Install XCompose file (optional)
    if xcompose_file:
        install_xcompose(xcompose_file)


if __name__ == "__main__":
    if sys.platform == "win32":
        raise RuntimeError(
            "This script is intended for Linux and should not be run on Windows."
        )
    main()
