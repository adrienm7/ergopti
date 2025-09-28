"""
MIT License

Copyright (c) 2024 Jean-Philippe Molla (Gepeto)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

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
        print("Ce script doit être lancé en sudo")
        sys.exit(1)


def show_help():
    """Display help information."""
    print(
        "Utilisation : install_xkb.py [fichier XKB] [fichier XCompose (optionnel)]"
    )
    print(
        "Ce script installe un fichier XKB spécifié et met à jour les fichiers LST et XML correspondants."
    )


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
        print(f"Le fichier XKB est déjà installé : {destination_file}")
    else:
        shutil.copy(source, destination_file)
        print(f"Le fichier XKB a été copié avec succès : {destination_file}")


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
    """Update the XML file by inserting a new variant element."""
    if not file_exists(file_path):
        print(f"Fichier non trouvé : {file_path}")
        return

    tree = ET.parse(file_path)
    root = tree.getroot()

    for layout in root.findall(".//layout"):
        name = layout.find("./configItem/name")
        if name is not None and name.text == "fr":
            variant_list = layout.find("variantList")
            if variant_list is not None:
                # Verify if the section already exists
                if any(
                    variant.find("./configItem/name").text == symbols_line
                    for variant in variant_list.findall("variant")
                ):
                    print(
                        f"La variante '{symbols_line}' existe déjà dans le fichier XML."
                    )
                    return

                backup_file(file_path)

                new_variant = ET.Element("variant")
                config_item = ET.SubElement(new_variant, "configItem")
                name_elem = ET.SubElement(config_item, "name")
                description_elem = ET.SubElement(config_item, "description")
                name_elem.text = symbols_line
                description_elem.text = name_line
                variant_list.insert(0, new_variant)
                root = prettify_xml(root)  # Prettify the XML before saving
                tree.write(file_path, encoding="utf-8", xml_declaration=True)
                print("XML mis à jour avec succès.")
                return

    print("Élément 'layout' avec 'name=fr' non trouvé.")


def update_lst(file_path, symbols_line, name_line):
    """Update the LST file by inserting a new line under the '! variant' section."""
    if not file_exists(file_path):
        print(f"Fichier non trouvé : {file_path}")
        return

    with open(file_path, "r") as file:
        lines = file.readlines()

    variant_section_found = False
    symbols_line_exists = False
    for i, line in enumerate(lines):
        if line.startswith("! variant"):
            variant_section_found = True
            continue  # Continue to check lines within this section

        if variant_section_found:
            if symbols_line in line:
                symbols_line_exists = True
                break  # symbols_line already exists, no need to update

    if not variant_section_found:
        print("Section '! variant' non trouvée dans le fichier LST.")
        return

    if symbols_line_exists:
        print(
            f"La ligne '{symbols_line}' existe déjà dans la section '! variant' du fichier LST."
        )
        return

    backup_file(file_path)

    # Insert the new line under '! variant' section
    for i, line in enumerate(lines):
        if line.startswith("! variant"):
            lst_line = f"  {symbols_line:<15} fr: {name_line}\n"
            lines.insert(i + 1, lst_line)
            break

    with open(file_path, "w") as file:
        file.writelines(lines)
    print("Fichier LST mis à jour avec succès.")


def validate_file(file_path, extension):
    """Check if the file exists and has the correct extension."""
    if not os.path.isfile(file_path):
        print(f"Le fichier {file_path} n'existe pas.")
        return False
    if not file_path.endswith(extension):
        print(f"L'extension de {file_path} doit être {extension}")
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
    if validate_file(xcompose_file, ".XCompose"):  # Validate the XCompose file
        user_choice = (
            input(
                "Le fichier existe déjà. Voulez-vous le remplacer ? (Oui/Non) "
            )
            .strip()
            .lower()
        )
        if user_choice not in ["oui", "o"]:
            print("Installation XCompose annulée.")
            return

    # Get the username of the user who invoked sudo
    username = os.getenv("SUDO_USER")
    if not username:
        print(
            "Impossible de récupérer le nom d'utilisateur pour l'installation de XCompose."
        )
        return

    # Get the home directory of the user
    home_dir = os.path.expanduser(f"~{username}")
    xcompose_destination_file = os.path.join(home_dir, ".XCompose")

    # Copy the XCompose file to the user's home directory
    shutil.copy(xcompose_file, xcompose_destination_file)
    print(
        f"Le fichier XCompose a été copié avec succès : {xcompose_destination_file}"
    )

    # Get the user ID and group ID
    uid = pwd.getpwnam(username).pw_uid
    gid = pwd.getpwnam(username).pw_gid

    # Change file ownership to the user
    if hasattr(os, "chown"):
        try:
            os.chown(xcompose_destination_file, uid, gid)
        except Exception as e:
            print(f"Erreur lors du chown : {e}")
    else:
        print("os.chown n’est pas disponible sur cette plateforme (Windows).")

    # Optionally, set file permissions
    # os.chmod(xcompose_destination_file, 0o644)  # Read and write for user, read for others

    print(
        f"Les permissions du fichier XCompose ont été mises à jour pour l'utilisateur '{username}'."
    )


def update_xkb_symbols(source_file, symbols_line, system_file):
    """
    Copy a specific section from the XKB file to the end of a system file.

    :param source_file: Path to the source XKB file.
    :param symbols_line: The key of the section to be copied (e.g., "optimot_ergo").
    :param system_file: Path to the system file where the section should be appended.
    """
    if not file_exists(system_file):
        print(f"Fichier non trouvé : {system_file}")
        return

    # Check if the section already exists in the system file
    with open(system_file, "r") as file:
        if f'xkb_symbols "{symbols_line}"' in file.read():
            print(
                f"La section '{symbols_line}' existe déjà dans {system_file}."
            )
            return

    with open(source_file, "r") as file:
        lines = file.readlines()

    section_found = False
    section_lines = []
    brace_level = 0
    previous_line = ""

    for line in lines:
        if f'xkb_symbols "{symbols_line}"' in line and "{" in line:
            section_found = True
            section_lines.append(
                previous_line
            )  # Add the line before the section
            brace_level = 0

        if section_found:
            section_lines.append(line)
            brace_level += line.count("{")
            brace_level -= line.count("}")

            # Check if the section ends (look for '};')
            if brace_level == 0 and line.strip().endswith("};"):
                break

        previous_line = line

    if not section_found or brace_level != 0:
        print(
            f"Section correspondant à '{symbols_line}' non trouvée ou incomplète dans {source_file}."
        )
        return

    backup_file(system_file)

    # Append the section to the system file
    with open(system_file, "a") as file:
        file.writelines(section_lines)
        print(f"Section copiée avec succès dans {system_file}")


def update_xkb_types(source_file, system_file):
    """
    Copy a specific xkb_types section from the XKB file and insert it into a designated section in the system file.

    :param source_file: Path to the source XKB file.
    :param system_file: Path to the system file where the section should be inserted.
    """
    if not file_exists(system_file):
        print(f"Fichier non trouvé : {system_file}")
        return

    try:
        with open(source_file, "r") as file:
            source_lines = file.readlines()

        # TODO: auto discover of types to copy
        sections_to_copy = [
            "SEVEN_LEVEL_KEYS",
        ]
        collected_sections = {section: [] for section in sections_to_copy}

        current_section = None
        brace_level = 0
        for line in source_lines:
            if any(f'type "{section}"' in line for section in sections_to_copy):
                current_section = next(
                    section
                    for section in sections_to_copy
                    if f'type "{section}"' in line
                )
                brace_level = 0

            if current_section:
                brace_level += line.count("{")
                brace_level -= line.count("}")

                collected_sections[current_section].append(line)
                if brace_level == 0:
                    current_section = None

        with open(system_file, "r") as file:
            system_lines = file.readlines()

        # Vérifier si les sections existent déjà dans le fichier système
        for section in sections_to_copy:
            if any(f'type "{section}"' in line for line in system_lines):
                print(f"La section '{section}' existe déjà dans {system_file}.")
                # TODO: replace content instead of exiting
                return

        insertion_point = None
        section_found = False
        brace_level = 0
        for i, line in enumerate(system_lines):
            if 'default partial xkb_types "default"' in line:
                section_found = True
                brace_level = 0

            if section_found:
                brace_level += line.count("{")
                brace_level -= line.count("}")

                if brace_level == 0:
                    section_found = False
                    insertion_point = i  # Found the matching closing brace
                    break

        if insertion_point is not None:
            backup_file(system_file)

            # Insert the collected sections before the matching closing brace
            section_insertion = "\n"
            for section in sections_to_copy:
                if collected_sections[section]:
                    section_insertion += "".join(collected_sections[section])

            system_lines.insert(insertion_point, section_insertion)
            with open(system_file, "w") as file:
                file.writelines(system_lines)
            print(f"Sections copiées avec succès dans {system_file}")
        else:
            print(f"Section cible non trouvée dans {system_file}.")

    except IOError as e:
        print(f"Erreur lors de la lecture/écriture des fichiers : {e}")


def main(args):
    check_sudo()

    if len(args) < 2 or args[1] in ["-h", "--help"]:
        show_help()
        return

    xkb_file = args[1]
    if not validate_file(xkb_file, ".xkb"):  # Validation du fichier XKB
        sys.exit(1)

    # Extraction des informations nécessaires à partir du fichier XKB
    symbols_line, name_line = extract_xkb_info(xkb_file)

    # Copie du fichier XKB dans le répertoire approprié – NE FONCTIONNE PAS FORCÉMENT ; dépend de la version de X11 !
    # xkb_dest_dir = f"{xkb_folder}/symbols/"
    # install_file(xkb_file, xkb_dest_dir)

    # Mise à jour des symbols XKB
    xkb_symbols_file = f"{xkb_folder}/symbols/fr"
    update_xkb_symbols(xkb_file, symbols_line, xkb_symbols_file)

    # Mise à jour des types XKB
    xkb_types_file = f"{xkb_folder}/types/extra"
    update_xkb_types(xkb_file, xkb_types_file)

    # Mise à jour du fichier LST
    lst_file = f"{xkb_folder}/rules/evdev.lst"
    update_lst(lst_file, symbols_line, name_line)

    # Mise à jour du fichier XML
    xml_file = f"{xkb_folder}/rules/evdev.xml"
    update_xml(xml_file, symbols_line, name_line)

    # Installation du fichier XCompose (optionnel)
    xcompose_file = args[2] if len(args) > 2 else None
    if xcompose_file:
        install_xcompose(xcompose_file)  # Install the XCompose file

if __name__ == "__main__":
    if sys.platform == "win32":
        raise RuntimeError(
            "Ce script ne doit pas être lancé sous Windows : il est prévu pour Linux."
        )

    if len(sys.argv) < 2:
        print(
            "Mode automatique : recherche du fichier .xkb le plus récent et du .XCompose dans le dossier courant..."
        )
        xkb_files = glob.glob(os.path.join(os.path.dirname(__file__), "*.xkb"))
        xcompose_files = glob.glob(
            os.path.join(os.path.dirname(__file__), "*.XCompose")
        )
        if not xkb_files:
            print("Aucun fichier .xkb trouvé.")
            sys.exit(1)
        # Sélectionne le .xkb le plus récent
        xkb_file = max(xkb_files, key=os.path.getmtime)
        print(f"Fichier XKB le plus récent trouvé : {xkb_file}")
        xcompose_file = xcompose_files[0] if xcompose_files else None
        if xcompose_file:
            print(f"Fichier XCompose trouvé : {xcompose_file}")
            args = [sys.argv[0], xkb_file, xcompose_file]
        else:
            args = [sys.argv[0], xkb_file]
        main(args)
    else:
        main(sys.argv)
