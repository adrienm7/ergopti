import os
from pathlib import Path
import re


def modify_and_copy_keylayout_files():
    # Répertoire contenant le script
    directory_path = Path(__file__).parent

    # Nouveau contenu pour remplacer <modifierMap id="f4" defaultIndex="0">
    modifier_map_replacement = """\t<modifierMap id="commonModifiers" defaultIndex="0">
\t\t<keyMapSelect mapIndex="0">
\t\t\t<modifier keys=""/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="1">
\t\t\t<modifier keys="anyShift"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="2">
\t\t\t<modifier keys="caps"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="3">
\t\t\t<modifier keys="anyShift caps"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="4">
\t\t\t<modifier keys="anyOption"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="5">
\t\t\t<modifier keys="anyShift anyOption"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="6">
\t\t\t<modifier keys="anyShift caps anyOption"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="7">
\t\t\t<modifier keys="caps anyOption"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="8">
\t\t\t<modifier keys="anyShift anyOption control caps?"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="9">
\t\t\t<modifier keys="command caps? anyOption? control?"/>
\t\t\t<modifier keys="control caps? anyOption?"/>
\t\t</keyMapSelect>
\t\t<keyMapSelect mapIndex="10">
\t\t\t<modifier keys="anyShift command caps? anyOption? control?"/>
\t\t\t<modifier keys="anyShift control caps?"/>
\t\t</keyMapSelect>
\t</modifierMap>"""

    # Contenu à ajouter sous <keyMap index="4"> et à créer pour <keyMap index="9">
    key_map_addition = """\t\t\t<key code="6" output="c"/> <!-- Sur É -->
\t\t\t<key code="7" action="v"/> <!-- Sur À -->
\t\t\t<key code="50" output="x"/> <!-- Sur Ê -->
\t\t\t<key code="12" action="z"/> <!-- Sur È -->"""

    # Nouveau bloc pour <keyMap index="9">
    key_map_index_9 = f"""<keyMap index="9">
{key_map_addition}
\t\t</keyMap>"""

    # Parcourt tous les fichiers se terminant par _v0.keylayout
    for file_path in directory_path.glob("*_v0.keylayout"):
        # Génère le nouveau nom de fichier sans le suffixe _v0
        new_file_path = file_path.with_name(
            file_path.stem.replace("_v0", "") + file_path.suffix
        )

        # Lis le contenu du fichier original
        with file_path.open("r", encoding="utf-8") as original_file:
            content = original_file.read()

        # Effectue les remplacements demandés
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

        # Remplacements bidirectionnels pour les codes
        modified_content = re.sub(r'code="50"', "TEMP_CODE", modified_content)
        modified_content = re.sub(r'code="10"', 'code="50"', modified_content)
        modified_content = re.sub(r"TEMP_CODE", 'code="10"', modified_content)

        # Remplacement du bloc <modifierMap id="f4" defaultIndex="0">
        modified_content = re.sub(
            r"<modifierMap id=\"f4\" defaultIndex=\"0\">.*?</modifierMap>",
            modifier_map_replacement,
            modified_content,
            flags=re.DOTALL,
        )

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

        # Écrit le contenu modifié dans un fichier avec le nouveau nom
        with new_file_path.open("w", encoding="utf-8") as new_file:
            new_file.write(modified_content)

        print(f"Fichier modifié et copié : {new_file_path}")


# Exécution principale
if __name__ == "__main__":
    modify_and_copy_keylayout_files()
