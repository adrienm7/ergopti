import os
from pathlib import Path
import re


# Corrige les .keylayouts sortis par KbdEdit
def modify_and_copy_keylayout_files():
    # Répertoire contenant le script
    directory_path = Path(__file__).parent

    # Raccourcis personnalisés sur les lettres accentuées
    key_map_addition = """\t\t\t<key code="6" output="c"/> <!-- Sur É -->
\t\t\t<key code="7" action="v"/> <!-- Sur À -->
\t\t\t<key code="50" output="x"/> <!-- Sur Ê -->
\t\t\t<key code="12" action="z"/> <!-- Sur È -->"""

    # Nouveau bloc pour <keyMap index="9">
    key_map_index_9 = f"""<keyMap index="9">
{key_map_addition}
\t\t</keyMap>"""

    # Ligne à ajouter pour <keyMapSelect mapIndex="9">
    key_map_select_addition = """\t\t<keyMapSelect mapIndex="9">
\t\t\t<modifier keys="command caps? anyOption? control?"/>
\t\t\t<modifier keys="control caps? anyOption?"/>
\t\t</keyMapSelect>"""

    # Parcourt tous les fichiers se terminant par _v0.keylayout
    for file_path in directory_path.glob("*_v0.keylayout"):
        # Génère le nouveau nom de fichier sans le suffixe _v0
        new_file_path = file_path.with_name(
            file_path.stem.replace("_v0", "") + file_path.suffix
        )

        # Lis le contenu du fichier original
        with file_path.open("r", encoding="utf-8") as original_file:
            content = original_file.read()

        # Corrige le keylayout où les symboles <, > et & sont mal encodés et ne s’écrivent pas
        modified_content = (
            content.replace(
                """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&lt;"/>""",
                """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&#x003C;"/>""",
            )
            .replace(
                """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&gt;"/>""",
                """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&#x003E;"/>""",
            )
            .replace(
                """\t\t<action id="&amp;">\n\t\t\t<when state="none" output="&amp;"/>""",
                """\t\t<action id="&amp;">\n\t\t\t<when state="none" output="&#x0026;"/>""",
            )
        )

        # Interversion des touches 10 et 50 (= et Ê) qui changent en ISO
        modified_content = re.sub(r'code="50"', "TEMP_CODE", modified_content)
        modified_content = re.sub(r'code="10"', 'code="50"', modified_content)
        modified_content = re.sub(r"TEMP_CODE", 'code="10"', modified_content)

        # Ajout du contenu sous <keyMap index="4">
        modified_content = re.sub(
            r"(<keyMap index=\"4\">)",
            r"\1\n" + key_map_addition,
            modified_content,
        )

        # Ajout ou création de <keyMap index="9"> après <keyMap index="8">
        if '<keyMap index="9">' not in modified_content:
            modified_content = re.sub(
                r"(<keyMap index=\"8\">.*?</keyMap>)",
                r"\1\n\t\t" + key_map_index_9,
                modified_content,
                flags=re.DOTALL,
            )

        # Ajout de <keyMapSelect mapIndex="9"> après <keyMapSelect mapIndex="8">
        modified_content = re.sub(
            r"(<keyMapSelect mapIndex=\"8\">.*?</keyMapSelect>)",
            r"\1\n" + key_map_select_addition,
            modified_content,
            flags=re.DOTALL,
        )

        # Écrit le contenu modifié dans un fichier avec le nouveau nom
        with new_file_path.open("w", encoding="utf-8") as new_file:
            new_file.write(modified_content)

        print(f"Fichier modifié et copié : {new_file_path}")


# Exécution principale
if __name__ == "__main__":
    modify_and_copy_keylayout_files()
