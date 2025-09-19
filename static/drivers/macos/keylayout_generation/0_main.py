import re
from pathlib import Path

from bundle_creation import create_bundle
from keylayout_correction import correct_keylayout
from keylayout_plus_creation import create_keylayout_plus


def main(
    file_name: str = "",
    input_directory: str = "",
    output_directory: Path = None,
    overwrite: bool = False,
) -> str:
    """
    Main entry point: generate corrected & plus keylayouts and create a bundle from them.

    Processes one or more v0 keylayouts, generates their corrected and _plus versions,
    and builds a macOS bundle containing these keylayouts.

    Returns:
        str: Path to the generated bundle zip file (as string).
            If the bundle already exists and overwrite=False, returns the path to the existing bundle.
    """

    # Determine output directory
    if output_directory:
        output_directory = Path(output_directory).resolve()
    else:
        # If no path is provided, use the parent directory of this file
        output_directory = Path(__file__).resolve().parent.parent

    # Determine input directory
    if input_directory:
        base_dir = Path(input_directory).resolve()
    else:
        # If no path is provided, use the "../raw_kbdedit_keylayouts" folder
        base_dir = (
            Path(__file__).resolve().parent.parent / "raw_kbdedit_keylayouts"
        )

    # Find files to process
    if file_name:
        kbdedit_file_paths = [base_dir / file_name]  # Process only one file
    else:
        kbdedit_file_paths = list(
            base_dir.glob("*_v0.keylayout")
        )  # All _v0 keylayouts

    last_bundle_path: str = ""
    for kbdedit_file_path in kbdedit_file_paths:
        log_section(f"Processing {kbdedit_file_path.name}")

        # Extract version from filename
        match = re.search(r"_v(\d+\.\d+\.\d+)", kbdedit_file_path.name)
        version = match.group(1) if match else "vX.X.X"
        print(f"Layout version: {version}")

        base_file_path = process_keylayout_v0(
            kbdedit_file_path, output_directory, overwrite
        )
        plus_file_path = process_keylayout_plus(
            base_file_path, output_directory, overwrite
        )

        bundle_file_path = build_bundle(
            version,
            output_directory,
            overwrite,
            [base_file_path, plus_file_path],
        )
        last_bundle_path = str(bundle_file_path)

    return last_bundle_path


def log_section(title: str) -> None:
    """Print a clear section separator for logs."""
    section_text = f"📂 {title}"
    print("\n" + "=" * (len(section_text) + 1))
    print(section_text)
    print("=" * (len(section_text) + 1))


def can_overwrite_file(file_path: Path, overwrite: bool) -> bool:
    """
    Handle logging when a file already exists.

    Returns:
        bool: True if we proceed with overwrite or file doesn't exist, False if we skip.
    """
    if file_path.exists():
        print(
            f"\t⚠️  Destination file already exists: {file_path}"
        )  # Needs double space after emoji
        if overwrite:
            print(
                f"\t✏️  Overwriting: {file_path}"
            )  # Needs double space after emoji
            return True
        else:
            print(f"\t🚫 Skipping modification: {file_path}")
            return False
    return True


def process_keylayout_v0(
    kbdedit_file_path: Path, output_directory: Path, overwrite: bool
) -> Path:
    """Open, correct and save the base keylayout (v0 → normal)."""
    base_file_path = output_directory / (
        "Ergopti Standard" + kbdedit_file_path.suffix
    )

    print(
        f"➡️  Creating corrected keylayout from: {kbdedit_file_path}"
    )  # Needs double space after emoji

    if not can_overwrite_file(base_file_path, overwrite):
        return base_file_path

    with kbdedit_file_path.open("r", encoding="utf-8") as f:
        content = f.read()

    content_corrected = correct_keylayout(content)
    with base_file_path.open("w", encoding="utf-8") as f:
        f.write(content_corrected)

    print(f"✅ Corrected keylayout saved at: {base_file_path}")
    return base_file_path


def process_keylayout_plus(
    base_file_path: Path, output_directory: Path, overwrite: bool
) -> Path:
    """Open a corrected keylayout and create the _plus version."""
    plus_file_path = output_directory / ("Ergopti Plus" + base_file_path.suffix)

    print(
        f"➡️  Creating plus version from: {base_file_path}"
    )  # Needs double space after emoji

    if not can_overwrite_file(plus_file_path, overwrite):
        return plus_file_path

    with base_file_path.open("r", encoding="utf-8") as f:
        content = f.read()

    content_plus = create_keylayout_plus(content)
    with plus_file_path.open("w", encoding="utf-8") as f:
        f.write(content_plus)

    print(f"✅ Keylayout plus saved at: {plus_file_path}")
    return plus_file_path


def build_bundle(
    version: str,
    output_directory: Path,
    overwrite: bool,
    keylayout_paths: list[Path],
    logo_paths: list[Path] = None,
) -> Path:
    """Build the macOS bundle with the generated keylayouts."""
    print(
        f"➡️  Building bundle for version {version}"
    )  # Needs double space after emoji

    # Determine logo files
    script_dir = Path(__file__).resolve().parent
    default_logos = [
        script_dir / "logo_ergopti.icns",
        script_dir / "logo_ergopti_plus.icns",
    ]
    logo_paths = [
        Path(p) for p in (logo_paths if logo_paths else default_logos)
    ]

    if len(logo_paths) < len(keylayout_paths):
        logo_paths += [None] * (len(keylayout_paths) - len(logo_paths))
    elif len(logo_paths) > len(keylayout_paths):
        logo_paths = logo_paths[: len(keylayout_paths)]

    bundle_file_path = output_directory / f"Ergopti_{version}.bundle"
    bundle_zip_path = bundle_file_path.parent / (bundle_file_path.name + ".zip")
    if not can_overwrite_file(bundle_zip_path, overwrite):
        return bundle_zip_path

    create_bundle(
        version,
        output_directory,
        keylayout_paths,
        logo_paths,
    )

    print(f"✅ Bundle created at: {bundle_zip_path}")
    return bundle_zip_path


if __name__ == "__main__":
    main("Ergopti_v2.2.0_v0.keylayout", overwrite=True)
