import os
from pathlib import Path
import re


def modify_and_copy_keylayout_files():
    # Répertoire contenant le script
    directory_path = Path(__file__).parent

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
        modified_content = content.replace(
            """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&lt;"/>""",
            """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&#x003C;"/>""",
        ).replace(
            """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&gt;"/>""",
            """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&#x003E;"/>""",
        )

        # Remplacements bidirectionnels pour les codes
        modified_content = re.sub(r'code="50"', "TEMP_CODE", modified_content)
        modified_content = re.sub(r'code="10"', 'code="50"', modified_content)
        modified_content = re.sub(r"TEMP_CODE", 'code="10"', modified_content)

        # Écrit le contenu modifié dans un fichier avec le nouveau nom
        with new_file_path.open("w", encoding="utf-8") as new_file:
            new_file.write(modified_content)

        print(f"Fichier modifié et copié : {new_file_path}")


# Exécution principale
if __name__ == "__main__":
    modify_and_copy_keylayout_files()
