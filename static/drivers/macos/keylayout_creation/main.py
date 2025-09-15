import re
from pathlib import Path

from bundle_creation import create_bundle  # ton create_bundle existant
from common import get_file_paths, read_file, write_file
from keylayout_correction import keylayout_corrector
from keylayout_plus_creation import create_keylayout_plus


def create_bundle_for_keylayouts(
    input_path: str = None,
    directory_path: str = None,
    output_dir: Path = None,
    logos: list[Path] = None,
):
    """
    Génère les keylayouts corrigés et _plus, puis crée un bundle macOS.
    logos : liste de fichiers logo correspondant aux keylayouts générés.
    """
    output_dir = (
        Path(output_dir).resolve()
        if output_dir
        else Path(__file__).resolve().parent.parent
    )
    file_paths, overwrite = get_file_paths(
        input_path, directory_path, suffix="_v0"
    )

    for file_path in file_paths:
        # Générer les keylayouts corrigés
        new_file_path = output_dir / (
            file_path.stem.replace("_v0", "") + file_path.suffix
        )
        new_file_path_plus = output_dir / (
            file_path.stem.replace("_v0", "_plus") + file_path.suffix
        )

        if not overwrite and new_file_path.exists():
            continue

        content = read_file(file_path)
        content_corrected = keylayout_corrector(content)
        write_file(new_file_path, content_corrected)

        content_corrected_plus = create_keylayout_plus(content_corrected)
        write_file(new_file_path_plus, content_corrected_plus)

        keylayout_files = [new_file_path, new_file_path_plus]

        # Extraire la version depuis le nom du fichier
        match = re.search(r"_v(\d+\.\d+\.\d+)", file_path.name)
        version = match.group(1) if match else "vX.X.X"

        # Préparer la liste des logos si fournie
        script_dir = Path(__file__).resolve().parent
        default_logos = [
            script_dir / "logo_ergopti.icns",
            script_dir / "logo_ergopti_plus.icns",
        ]
        logo_files = [Path(p) for p in (logos if logos else default_logos)]

        # Créer le bundle
        create_bundle(
            version=version,
            keylayout_files=keylayout_files,
            logo_files=logo_files,
            directory_path=output_dir,
            zip_bundle=True,
            cleanup=True,
        )


if __name__ == "__main__":
    create_bundle_for_keylayouts()
    # create_bundle_for_keylayouts("Ergopti_v2.2.0_v0.keylayout")
