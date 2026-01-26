import datetime
import importlib.util
import re
import sys
from pathlib import Path
from typing import Optional, Union

# Setup paths
script_dir = Path(__file__).resolve().parent
# The file now lives in xkb_generation/. Add the top-level drivers directory
# (two levels up) to sys.path so we can import sibling packages like
# 'utilities'. Example: static/drivers is script_dir.parent.parent
sys.path.insert(0, str(script_dir.parent.parent))  # Add drivers directory to path

# Import utilities
from utilities.keylayout_extraction import extract_version_enhanced
from utilities.logger import logger

# Import local modules using importlib
xcompose_spec = importlib.util.spec_from_file_location(
    "xcompose_creation", script_dir / "xcompose_creation.py"
)
xcompose_module = importlib.util.module_from_spec(xcompose_spec)
xcompose_spec.loader.exec_module(xcompose_module)
generate_xcompose = xcompose_module.generate_xcompose

xkb_spec = importlib.util.spec_from_file_location(
    "xkb_creation", script_dir / "xkb_creation.py"
)
xkb_module = importlib.util.module_from_spec(xkb_spec)
xkb_spec.loader.exec_module(xkb_module)
generate_xkb = xkb_module.generate_xkb


def main(
    keylayout_name: str = "",
    use_date_in_filename: bool = False,
    input_directory: Optional[Union[str, Path]] = None,
) -> None:
    """
    Main entry point for generating XKB and XCompose files from macOS keylayout(s).

    Args:
        keylayout_name (str): The base keylayout filename to use.
            If empty, process all .keylayout files in input_directory.
        use_date_in_filename (bool): Whether to append the date to the output filenames.
        input_directory (str | Path): Directory containing keylayout files.
            If None, use default macos dirs from bundles.
    """
    if input_directory:
        macos_dirs = [Path(input_directory)]
    else:
        macos_dirs = get_macos_dirs()

    all_keylayout_files = []
    if keylayout_name:
        # If a specific keylayout is named, search for it in all macos_dirs
        base_prefix = Path(keylayout_name).stem
        variants = [
            base_prefix,
            base_prefix + "_plus",
            base_prefix + "_plus_plus",
        ]
        for macos_dir in macos_dirs:
            for variant in variants:
                keylayout_path = macos_dir / f"{variant}.keylayout"
                if keylayout_path.is_file():
                    all_keylayout_files.append(keylayout_path)
    else:
        # Process all .keylayout files in all found directories
        for macos_dir in macos_dirs:
            keylayout_files = sorted(
                f
                for f in macos_dir.glob("*.keylayout")
                if not f.stem.endswith("_plus_plus")
                and not f.stem.endswith("_plus")
            )
            # For each, add its _plus variant if it exists
            plus_files = [
                macos_dir / f"{f.stem}_plus.keylayout" for f in keylayout_files
            ]
            plus_plus_files = [
                macos_dir / f"{f.stem}_plus_plus.keylayout"
                for f in keylayout_files
            ]
            all_keylayout_files.extend(keylayout_files)
            all_keylayout_files.extend(
                [pf for pf in plus_plus_files + plus_files if pf.is_file()]
            )

    for keylayout_path in all_keylayout_files:
        if not keylayout_path.is_file():
            logger.error("Keylayout file not found: %s", keylayout_path)
            continue
        keylayout = read_file(keylayout_path)

        xkb_template_path = Path(__file__).parent / "data" / "xkb_symbols.txt"
        if not xkb_template_path.is_file():
            logger.error("XKB template file not found: %s", xkb_template_path)
            continue
        xkb_template = read_file(xkb_template_path)

        variant = keylayout_path.stem
        layout_id, layout_name = create_layout_name(
            keylayout, variant, use_date_in_filename, keylayout_path
        )
        xkb_template = re.sub(
            r'xkb_symbols\s+"[^"]+"', f'xkb_symbols "{layout_id}"', xkb_template
        )
        xkb_template = re.sub(
            r'name\[Group1\]\s*=\s*"[^"]+";',
            f'name[Group1] = "{layout_name}";',
            xkb_template,
        )

        # Create output directory with version name
        version_name = extract_version_from_path(keylayout_path)

        linux_dir = Path(__file__).parent
        # place generated releases one level up from this xkb_generation/
        # directory so the output directories match the previous layout
        out_dir = linux_dir.parent / version_name
        out_dir.mkdir(exist_ok=True)

        # Copy the xkb types files
        try:
            data_dir = Path(__file__).parent / "data"
            src_types = data_dir / "xkb_types.txt"
            src_types_no_ctrl = data_dir / "xkb_types_without_ctrl.txt"

            dest_types = out_dir / src_types.name
            dest_types_no_ctrl = out_dir / src_types_no_ctrl.name

            # read/write preserves UTF-8 encoding
            dest_types.write_text(
                src_types.read_text(encoding="utf-8"), encoding="utf-8"
            )
            dest_types_no_ctrl.write_text(
                src_types_no_ctrl.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
        except OSError:
            logger.error("Failed to copy xkb types files into %s", out_dir)

        base_name = f"{layout_id}"
        xkb_out_path = out_dir / f"{base_name}.xkb"
        xcompose_out_path = out_dir / f"{base_name}.XCompose"

        logger.info("Generating XKB content for %s…", variant)
        xkb_content, mapped_symbols = generate_xkb(xkb_template, keylayout)
        save_file(xkb_out_path, xkb_content)

        logger.info("Generating XCompose content for %s…", variant)
        xcompose_content = generate_xcompose(keylayout, mapped_symbols)
        save_file(xcompose_out_path, xcompose_content)


def get_macos_dirs():
    """
    Return a list of absolute paths to the macOS keylayout directories.
    Finds all .bundle directories and returns their Resources path.

    Returns:
        list[Path]: A list of paths to the macOS keylayout directories.

    Raises:
        FileNotFoundError: If the base macos directory does not exist.
    """
    # script location: static/drivers/linux/xkb_generation
    # -> want static/drivers/macos/bundles
    bundles_dir = Path(__file__).parent.parent.parent / "macos" / "bundles"
    if not bundles_dir.is_dir():
        logger.error("macOS bundles directory does not exist: %s", bundles_dir)
        raise FileNotFoundError(
            f"macOS bundles directory does not exist: {bundles_dir}"
        )

    bundle_dirs = list(bundles_dir.glob("*.bundle"))
    if not bundle_dirs:
        logger.warning("No .bundle directories found in %s", bundles_dir)
        return []

    resource_dirs = []
    for bundle in bundle_dirs:
        bundle_resources = bundle / "Contents" / "Resources"
        if bundle_resources.is_dir():
            logger.info("Found keylayout directory: %s", bundle_resources)
            resource_dirs.append(bundle_resources)

    return resource_dirs


def read_file(file_path: Union[str, Path]) -> str:
    """
    Read and return the content of a text file.

    Args:
        file_path (str | Path): Path to the file to read.

    Returns:
        str: The file content as a string.

    Raises:
        FileNotFoundError: If the file does not exist.
    """
    logger.info("Reading input from %s", file_path)
    file_path = Path(file_path)
    if not file_path.is_file():
        logger.error("File not found: %s", file_path)
        raise FileNotFoundError(f"File not found: {file_path}")
    with open(file_path, encoding="utf-8") as file:
        return file.read()


def save_file(file_path: Union[str, Path], content: str) -> None:
    """
    Write content to a text file.

    Args:
        file_path (str | Path): Path to the file to write.
        content (str): Content to write to the file.

    Raises:
        OSError: If writing fails.
    """
    logger.info("Writing output to %s", file_path)
    file_path = Path(file_path)
    with open(file_path, "w", encoding="utf-8") as file:
        file.write(content)


def extract_version_from_layout_name(layout_name: str) -> str:
    """
    Extract version from layout name to create directory name.

    Args:
        layout_name: The layout display name.

    Returns:
        Version string for directory name, or "unknown_version".
    """
    # Search for version patterns like vX.Y.Z or vX_Y_Z
    match = re.search(r"v(\d+)[._](\d+)[._](\d+)", layout_name.lower())
    if match:
        return f"v{match.group(1)}_{match.group(2)}_{match.group(3)}"

    # Fallback for shorter versions like vX.Y or vX_Y
    match = re.search(r"v(\d+)[._](\d+)", layout_name.lower())
    if match:
        return f"v{match.group(1)}_{match.group(2)}_0"

    return "unknown_version"


def extract_version_from_path(keylayout_path: Path) -> str:
    """
    Extract version from keylayout path to create a directory name.

    Args:
        keylayout_path: The path to the keylayout file.

    Returns:
        Version string for directory name, or "unknown_version".
    """
    path_str = str(keylayout_path).lower()

    # Search for version patterns like vX.Y.Z or vX_Y_Z in the path
    match = re.search(r"v(\d+)[._](\d+)[._](\d+)", path_str)
    if match:
        return f"v{match.group(1)}_{match.group(2)}_{match.group(3)}"

    # Fallback for shorter versions like vX.Y or vX_Y
    match = re.search(r"v(\d+)[._](\d+)", path_str)
    if match:
        return f"v{match.group(1)}_{match.group(2)}_0"

    # Fallback: extract from bundle directory name
    bundle_name = ""
    for parent in keylayout_path.parents:
        if parent.name.endswith(".bundle"):
            bundle_name = parent.name
            break
    if bundle_name:
        match = re.search(r"v(\d+)[._](\d+)[._](\d+)", bundle_name.lower())
        if match:
            return f"v{match.group(1)}_{match.group(2)}_{match.group(3)}"
        match = re.search(r"v(\d+)[._](\d+)", bundle_name.lower())
        if match:
            return f"v{match.group(1)}_{match.group(2)}_0"

    return "unknown_version"


def create_layout_name(
    keylayout: str,
    variant: str,
    use_date_in_filename: bool,
    keylayout_path: Path = None,
) -> tuple[str, str]:
    """
    Generate the layout id and display name from the variant and optionally the date.

    Args:
        keylayout (str): The keylayout file content.
        variant (str): The layout variant name.
        use_date_in_filename (bool): Whether to append the date to the output.
        keylayout_path (Path): Optional path to the keylayout file for version extraction.

    Returns:
        tuple[str, str]: (layout_id, layout_name)
    """
    layout_id = variant.replace(
        ".", "_"
    )  # If there are dots in the id (here in version number), the layout doesn't work

    # Determine variant type based on filename
    stem = variant.lower()
    is_plusplus = stem.endswith("plus_plus")
    is_plus = "plus" in stem and not is_plusplus

    # Extract version from keylayout content
    try:
        version = extract_version_enhanced(keylayout, keylayout_path)
        # Clean version: remove " Plus", " Plus Plus" suffixes
        display_version = (
            version.replace(" Plus Plus", "").replace(" Plus", "").strip()
        )
    except (ValueError, AttributeError):
        # If no version found, use empty string
        display_version = ""

    # Fallback: extract version from filename if not found in content
    if not display_version:
        # Try to extract version from variant filename (e.g., "Ergopti_v2_2_0_plus_plus" -> "v2.2.0")
        version_match = re.search(r"v(\d+)_(\d+)_(\d+)", variant.lower())
        if version_match:
            display_version = f"v{version_match.group(1)}.{version_match.group(2)}.{version_match.group(3)}"

    # Generate display name with proper variant formatting
    if is_plusplus:
        layout_name = f"Français — Ergopti++ {display_version}".strip()
    elif is_plus:
        layout_name = f"Français — Ergopti+ {display_version}".strip()
    else:
        layout_name = f"Français — Ergopti {display_version}".strip()

    if use_date_in_filename:
        now = datetime.datetime.now()
        layout_id += f"_{now.year}_{now.month:02d}_{now.day:02d}_{now.hour:02d}h{now.minute:02d}"
        layout_name += f" {now.year}/{now.month:02d}/{now.day:02d} {now.hour:02d}:{now.minute:02d}"

    return layout_id, layout_name


if __name__ == "__main__":
    main(use_date_in_filename=False)
