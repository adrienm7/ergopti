"""
Main entry point for generating corrected and enhanced macOS keylayout files.
"""

import re
from pathlib import Path

from keylayout_correction import correct_keylayout
from keylayout_plus_creation import create_keylayout_plus
from utilities.bundle_creation import create_bundle
from utilities.information_extraction import extract_version_from_file
from utilities.logger import get_error_count, logger, reset_error_count


def main(
    file_name: str = "",
    input_directory: Path = None,
    output_directory: Path = None,
    overwrite: bool = False,
) -> None:
    """Main function to generate keylayout files and bundle from kbdedit files."""
    # Determine output directory
    if output_directory:
        output_directory = Path(output_directory).resolve()
    else:
        # If no path is provided, use the parent directory of this file
        output_directory = Path(__file__).resolve().parent.parent

    # Determine input directory
    if input_directory:
        kbdedit_files_directory = Path(input_directory).resolve()
    else:
        # If no path is provided, use the "../raw_kbdedit_keylayouts" folder
        kbdedit_files_directory = (
            Path(__file__).resolve().parent.parent / "raw_kbdedit_keylayouts"
        )

    # Find files to process
    if file_name:
        kbdedit_file_paths = [
            kbdedit_files_directory / file_name
        ]  # Process only one file
    else:
        kbdedit_file_paths = list(
            kbdedit_files_directory.glob("*_v0.keylayout")
        )  # All _v0 keylayouts

    processed = 0
    errors = 0
    reset_error_count()
    for kbdedit_file_path in kbdedit_file_paths:
        log_section(f"Processing {kbdedit_file_path.name}…")
        if not kbdedit_file_path.exists():
            logger.error("Source file does not exist: %s", kbdedit_file_path)
            errors += 1
            continue
        try:
            version = extract_version_from_file(kbdedit_file_path)
            logger.info("Layout version: %s", version)

            base_file_path = generate_keylayout(
                kbdedit_file_path, output_directory, overwrite
            )
            plus_file_path = generate_keylayout_plus(
                base_file_path, output_directory, overwrite
            )

            generate_bundle(
                version,
                output_directory,
                overwrite,
                [base_file_path, plus_file_path],
            )
            logger.success(
                "All files generated successfully for: %s",
                kbdedit_file_path.name,
            )
            processed += 1
        except (OSError, ValueError, RuntimeError) as e:
            logger.error("Error processing %s: %s", kbdedit_file_path.name, e)
            errors += 1

    logger.info("=" * 85)
    logger.info(
        "Processing complete. %d file(s) processed, %d error(s) (exceptions), %d error log(s).",
        processed,
        errors,
        get_error_count(),
    )
    logger.info("=" * 85)


def log_section(title: str) -> None:
    """Print a clear section separator for logs."""
    section_text = f"📂 {title}"
    logger.info("=" * (len(section_text) + 1))
    logger.info(section_text)
    logger.info("=" * (len(section_text) + 1))


def generate_keylayout(
    kbdedit_file_path: Path, output_directory: Path, overwrite: bool
) -> Path:
    """Generate a corrected keylayout file from the given kbdedit file."""
    logger.launch("Creating corrected keylayout from: %s", kbdedit_file_path)

    base_file_path = output_directory / (
        kbdedit_file_path.stem.replace("_v0", "") + kbdedit_file_path.suffix
    )
    if not can_overwrite_file(base_file_path, overwrite):
        return base_file_path

    content = kbdedit_file_path.read_text(encoding="utf-8")
    content_corrected = correct_keylayout(content)
    base_file_path.write_text(content_corrected, encoding="utf-8")

    logger.success("Corrected keylayout saved at: %s", base_file_path)
    return base_file_path


def generate_keylayout_plus(
    base_file_path: Path, output_directory: Path, overwrite: bool
) -> Path:
    """Generate the 'plus' version of a keylayout file."""
    plus_file_path = output_directory / (
        base_file_path.stem + "_plus" + base_file_path.suffix
    )

    logger.launch("Creating plus version from: %s", base_file_path)

    if not can_overwrite_file(plus_file_path, overwrite):
        return plus_file_path

    content = base_file_path.read_text(encoding="utf-8")
    content_plus = create_keylayout_plus(content)
    plus_file_path.write_text(content_plus, encoding="utf-8")

    logger.success("Keylayout plus saved at: %s", plus_file_path)
    return plus_file_path


def generate_bundle(
    version: str,
    output_directory: Path,
    overwrite: bool,
    keylayout_paths: list[Path],
    logo_paths: list[Path] = None,
) -> Path:
    """Generate a .bundle package containing the provided keylayout files."""
    logger.launch("Building bundle for version %s", version)

    match = re.search(r"(v\d+\.\d+\.\d+)", version)
    simple_version = match.group(1) if match else version
    bundle_name = f"Ergopti_{simple_version}.bundle"
    bundle_path = output_directory / bundle_name

    # Determine logo files
    script_dir = Path(__file__).resolve().parent
    default_logos = [
        script_dir / "files" / "logo_ergopti.icns",
        script_dir / "files" / "logo_ergopti_plus.icns",
    ]
    logo_paths = adjust_logo_paths(logo_paths, keylayout_paths, default_logos)

    if len(logo_paths) < len(keylayout_paths):
        logo_paths += [None] * (len(keylayout_paths) - len(logo_paths))
    elif len(logo_paths) > len(keylayout_paths):
        logo_paths = logo_paths[: len(keylayout_paths)]

    bundle_zip_path = bundle_path.with_suffix(".zip")
    if not can_overwrite_file(bundle_zip_path, overwrite):
        return bundle_zip_path

    create_bundle(
        bundle_path,
        version,
        keylayout_paths,
        logo_paths,
    )

    logger.success("Bundle created at: %s", bundle_zip_path)
    return bundle_zip_path


def adjust_logo_paths(
    logo_paths: list[Path],
    keylayout_paths: list[Path],
    default_logos: list[Path],
) -> list[Path]:
    """
    Adjusts the logo_paths list to match the length of keylayout_paths.
    Fills with None or trims as needed. Uses default_logos if logo_paths is None.
    """
    if not logo_paths:
        logo_paths = default_logos.copy()
    else:
        logo_paths = [Path(p) for p in logo_paths]
    if len(logo_paths) < len(keylayout_paths):
        logo_paths += [None] * (len(keylayout_paths) - len(logo_paths))
    elif len(logo_paths) > len(keylayout_paths):
        logo_paths = logo_paths[: len(keylayout_paths)]
    return logo_paths


def can_overwrite_file(file_path: Path, overwrite: bool) -> bool:
    """
    Handle deciding what to do if a file already exists.

    Returns:
        bool: True if we proceed with overwrite or file doesn't exist, False if we skip.
    """
    if file_path.exists():
        logger.warning("\t Destination file already exists: %s", file_path)
        if overwrite:
            logger.warning("\t✏️  Overwriting: %s", file_path)
            return True
        else:
            logger.warning("\t🚫 Skipping modification: %s", file_path)
            return False
    return True


if __name__ == "__main__":
    main("Ergopti_v2.2.0_v0.keylayout", overwrite=True)
