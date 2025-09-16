import re
from pathlib import Path

from bundle_creation import create_bundle
from keylayout_correction import correct_keylayout
from keylayout_plus_creation import create_keylayout_plus


def main(
    file_name: str = "",
    directory_path: str = "",
    output_dir: Path = None,
    overwrite: bool = False,
):
    """Main entry point: generate corrected & plus keylayouts and create a bundle from them."""

    # Determine output directory
    if output_dir:
        output_dir = Path(output_dir).resolve()
    else:
        # If no path is provided, use the parent directory of this file
        output_dir = Path(__file__).resolve().parent.parent

    # Determine input directory
    if directory_path:
        base_dir = Path(directory_path).resolve()
    else:
        # If no path is provided, use the "../raw_kbdedit_keylayouts" folder
        base_dir = (
            Path(__file__).resolve().parent.parent / "raw_kbdedit_keylayouts"
        )

    # Find files to process
    if file_name:
        file_paths = [base_dir / file_name]  # process only one file
    else:
        file_paths = list(base_dir.glob("*_v0.keylayout"))  # all _v0 keylayouts

    for file_path in file_paths:
        log_section(f"Processing {file_path.name}")

        # Extract version from filename
        match = re.search(r"_v(\d+\.\d+\.\d+)", file_path.name)
        version = match.group(1) if match else "vX.X.X"
        print(f"Layout version: {version}")

        base_file_path = process_keylayout_v0(file_path, output_dir, overwrite)
        plus_file_path = process_keylayout_plus(
            base_file_path, output_dir, overwrite
        )

        bundle_file = build_bundle(
            version,
            [base_file_path, plus_file_path],
            output_dir,
            overwrite=overwrite,
        )


def log_section(title: str):
    """Print a clear section separator for logs."""
    section_text = f"📂 {title}"
    print("\n" + "=" * (len(section_text) + 1))
    print(section_text)
    print("=" * (len(section_text) + 1))


def handle_existing_file(file_path: Path, overwrite: bool) -> bool:
    """
    Handle logging when a file already exists.
    Returns True if we should proceed with overwrite, False if we skip.
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
    file_path: Path, output_dir: Path, overwrite: bool
) -> Path:
    """Open, correct and save the base keylayout (v0 → normal)."""
    new_file_path = output_dir / (
        file_path.stem.replace("_v0", "") + file_path.suffix
    )

    print(
        f"➡️  Creating corrected keylayout from: {file_path}"
    )  # Needs double space after emoji

    if not handle_existing_file(new_file_path, overwrite):
        return new_file_path

    with file_path.open("r", encoding="utf-8") as f:
        content = f.read()

    content_corrected = correct_keylayout(content)
    with new_file_path.open("w", encoding="utf-8") as f:
        f.write(content_corrected)

    print(f"✅ Corrected keylayout saved at: {new_file_path}")
    return new_file_path


def process_keylayout_plus(
    base_file_path: Path, output_dir: Path, overwrite: bool
) -> Path:
    """Open a corrected keylayout and create the _plus version."""
    new_file_path_plus = output_dir / (
        base_file_path.stem.replace(".keylayout", "_plus.keylayout")
    )

    print(
        f"➡️  Creating plus version from: {base_file_path}"
    )  # Needs double space after emoji

    if not handle_existing_file(new_file_path_plus, overwrite):
        return new_file_path_plus

    with base_file_path.open("r", encoding="utf-8") as f:
        content = f.read()

    content_plus = create_keylayout_plus(content)
    with new_file_path_plus.open("w", encoding="utf-8") as f:
        f.write(content_plus)

    print(f"✅ Keylayout plus saved at: {new_file_path_plus}")
    return new_file_path_plus


def build_bundle(
    version: str,
    keylayout_files: list[Path],
    output_dir: Path,
    overwrite: bool,
    logos: list[Path] = None,
):
    """Build the macOS bundle with the generated keylayouts and logos."""
    print(f"📦 Building bundle for version {version}")

    script_dir = Path(__file__).resolve().parent
    default_logos = [
        script_dir / "logo_ergopti.icns",
        script_dir / "logo_ergopti_plus.icns",
    ]
    logo_files = [Path(p) for p in (logos if logos else default_logos)]

    bundle_dir = output_dir / f"Ergopti_{version}.bundle"

    zip_file = bundle_dir.parent / (bundle_dir.name + ".zip")
    if not handle_existing_file(zip_file, overwrite):
        return zip_file

    create_bundle(
        version=version,
        keylayout_files=keylayout_files,
        logo_files=logo_files,
        directory_path=output_dir,
        zip_bundle=True,
        cleanup=True,
    )

    print(f"✅ Bundle created at: {bundle_dir}")
    return bundle_dir


if __name__ == "__main__":
    main("Ergopti_v2.2.0_v0.keylayout", overwrite=True)
