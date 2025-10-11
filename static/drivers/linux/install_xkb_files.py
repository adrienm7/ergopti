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
    print()
    print(
        "Mode automatique : lance le script sans arguments pour sélectionner une version"
    )


def select_version():
    """Let user select between normal, plus, or plus_plus version."""
    print("Sélectionnez la version d'Ergopti à installer :")
    print("1. Ergopti (version normale)")
    print("2. Ergopti+ (version plus)")
    print("3. Ergopti++ (version plus plus)")

    while True:
        choice = input("Votre choix (1, 2 ou 3) : ").strip()
        if choice == "1":
            return "normal"
        elif choice == "2":
            return "plus"
        elif choice == "3":
            return "plus_plus"
        else:
            print("Choix invalide. Veuillez entrer 1, 2 ou 3.")


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
                "Le fichier XCompose existe déjà. Voulez-vous l’écraser ? (Oui/Non) "
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
    Improved to better handle existing sections.

    :param source_file: Path to the source XKB file.
    :param symbols_line: The key of the section to be copied (e.g., "optimot_ergo").
    :param system_file: Path to the system file where the section should be appended.
    """
    if not file_exists(system_file):
        print(f"Fichier non trouvé : {system_file}")
        return

    # Récupère la section à copier depuis le fichier source
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
            f"Section correspondant à '{symbols_line}' non trouvée ou incomplète dans {source_file}."
        )
        return

    # Lit le fichier système pour voir si la section existe déjà
    with open(system_file, "r") as file:
        system_lines = file.readlines()

    # Recherche plus robuste de la section existante
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
        # Remplace la section existante
        print(
            f"Section '{symbols_line}' trouvée aux lignes {existing_start_idx + 1}-{existing_end_idx + 1}, remplacement..."
        )
        system_lines[existing_start_idx : existing_end_idx + 1] = section_lines
        with open(system_file, "w") as file:
            file.writelines(system_lines)
        print(
            f"Section '{symbols_line}' mise à jour avec succès dans {system_file}"
        )
    else:
        # Ajoute la section à la fin si elle n'existe pas
        print(
            f"Section '{symbols_line}' non trouvée, ajout à la fin du fichier..."
        )
        with open(system_file, "a") as file:
            file.write("\n")  # Ensure newline before new section
            file.writelines(section_lines)
        print(f"Section '{symbols_line}' ajoutée avec succès à {system_file}")


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

        # Découverte automatique des types à copier
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

        # Vérifier et remplacer les sections existantes
        sections_replaced = set()
        i = 0
        while i < len(system_lines):
            line = system_lines[i]

            # Chercher si cette ligne correspond à une section à copier
            section_found = None
            for section in sections_to_copy:
                if f'type "{section}"' in line and "{" in line:
                    section_found = section
                    break

            if section_found:
                # Trouver la fin de cette section
                start_idx = i
                brace_level = 0
                end_idx = None

                for j in range(i, len(system_lines)):
                    brace_level += system_lines[j].count("{")
                    brace_level -= system_lines[j].count("}")
                    if brace_level == 0 and system_lines[j].strip().endswith(
                        "};"
                    ):
                        end_idx = j
                        break

                if end_idx is not None:
                    # Remplacer la section existante
                    system_lines[start_idx : end_idx + 1] = collected_sections[
                        section_found
                    ]
                    sections_replaced.add(section_found)
                    print(
                        f"Section '{section_found}' remplacée avec succès dans {system_file}"
                    )
                    # Ajuster l'index pour continuer après la section insérée
                    i = start_idx + len(collected_sections[section_found])
                    continue

            i += 1

        # Insérer les sections qui n'existaient pas
        sections_to_insert = [
            s for s in sections_to_copy if s not in sections_replaced
        ]

        if sections_to_insert:
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
                        insertion_point = i
                        break

            if insertion_point is not None:
                backup_file(system_file)
                # Insérer les nouvelles sections avant l'accolade fermante
                section_insertion = "\n"
                for section in sections_to_insert:
                    if collected_sections[section]:
                        section_insertion += "".join(
                            collected_sections[section]
                        )

                system_lines.insert(insertion_point, section_insertion)
                print(
                    f"Nouvelles sections insérées avec succès dans {system_file}"
                )
            else:
                print(f"Section cible non trouvée dans {system_file}.")

        # Écrire le fichier modifié
        with open(system_file, "w") as file:
            file.writelines(system_lines)

        if sections_replaced:
            print(f"Total de {len(sections_replaced)} section(s) remplacée(s)")
        if sections_to_insert:
            print(f"Total de {len(sections_to_insert)} section(s) insérée(s)")

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
            "Mode automatique : sélection de la version d'Ergopti à installer..."
        )

        # Let user select version
        version = select_version()

        # Find files based on version
        script_dir = os.path.dirname(__file__)
        xkb_files = find_xkb_files_by_version(script_dir, version)
        xcompose_files = glob.glob(os.path.join(script_dir, "*.XCompose"))

        if not xkb_files:
            print(f"Aucun fichier .xkb trouvé pour la version {version}.")
            print("Recherche dans les sous-dossiers...")
            # Search in subdirectories
            for subdir in os.listdir(script_dir):
                subdir_path = os.path.join(script_dir, subdir)
                if os.path.isdir(subdir_path):
                    xkb_files.extend(
                        find_xkb_files_by_version(subdir_path, version)
                    )

        if not xkb_files:
            print(f"Aucun fichier .xkb trouvé pour la version {version}.")
            sys.exit(1)

        # Select the most recent XKB file
        xkb_file = max(xkb_files, key=os.path.getmtime)
        print(f"Fichier XKB sélectionné : {xkb_file}")

        # Find corresponding XCompose file
        xkb_basename = os.path.basename(xkb_file).replace(".xkb", "")
        xcompose_file = None
        for xc_file in xcompose_files:
            if xkb_basename in os.path.basename(xc_file):
                xcompose_file = xc_file
                break

        if not xcompose_file and xcompose_files:
            xcompose_file = xcompose_files[0]

        if xcompose_file:
            print(f"Fichier XCompose trouvé : {xcompose_file}")
            args = [sys.argv[0], xkb_file, xcompose_file]
        else:
            args = [sys.argv[0], xkb_file]
        main(args)
    else:
        main(sys.argv)
