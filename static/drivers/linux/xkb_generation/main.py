import datetime
import re
import sys
from pathlib import Path
from typing import Optional, Union

sys.path.append(str(Path(__file__).resolve().parent.parent.parent))
from utilities.keylayout_extraction import extract_name_from_file
from utilities.logger import logger
from xcompose_creation import generate_xcompose
from xkb_creation import generate_xkb


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
            If None, use default macos dir.
    """
    macos_dir = Path(input_directory) if input_directory else get_macos_dir()

    if keylayout_name:
        # Process only the specified keylayout (and its _plus variants)
        base_prefix = Path(keylayout_name).stem
        variants = [
            base_prefix,
            base_prefix + "_plus",
            base_prefix + "_plus_plus",
        ]
        keylayout_files = [macos_dir / f"{v}.keylayout" for v in variants]
    else:
        # Process all .keylayout files (excluding _plus) in the directory
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
            macos_dir / f"{f.stem}_plus_plus.keylayout" for f in keylayout_files
        ]
        keylayout_files += [
            pf for pf in plus_plus_files + plus_files if pf.is_file()
        ]

    for keylayout_path in keylayout_files:
        if not keylayout_path.is_file():
            logger.error("Keylayout file not found: %s", keylayout_path)
            continue
        keylayout = read_file(keylayout_path)

        xkb_template_path = Path(__file__).parent / "data" / "base.xkb"
        if not xkb_template_path.is_file():
            logger.error("XKB template file not found: %s", xkb_template_path)
            continue
        xkb_template = read_file(xkb_template_path)

        variant = keylayout_path.stem
        layout_id, layout_name = create_layout_name(
            keylayout, variant, use_date_in_filename
        )
        xkb_template = re.sub(
            r'xkb_symbols\s+"[^"]+"', f'xkb_symbols "{layout_id}"', xkb_template
        )
        xkb_template = re.sub(
            r'name\[Group1\]\s*=\s*"[^"]+";',
            f'name[Group1] = "{layout_name}";',
            xkb_template,
        )

        out_dir = Path(__file__).parent.parent.resolve()
        base_name = f"{layout_id}"
        xkb_out_path = out_dir / f"{base_name}.xkb"
        xcompose_out_path = out_dir / f"{base_name}.XCompose"

        logger.info("Generating XKB content for %s…", variant)
        xkb_content, mapped_symbols = generate_xkb(xkb_template, keylayout)
        save_file(xkb_out_path, xkb_content)

        logger.info("Generating XCompose content for %s…", variant)
        xcompose_content = generate_xcompose(keylayout, mapped_symbols)
        save_file(xcompose_out_path, xcompose_content)


def get_macos_dir():
    """
    Return the absolute path to the macOS keylayout directory.

    Returns:
        Path: Path to the macOS keylayout directory.

    Raises:
        FileNotFoundError: If the directory does not exist.
    """
    macos_dir = Path(__file__).parent.parent.parent / "macos"
    if not macos_dir.is_dir():
        logger.error("macos directory does not exist: %s", macos_dir)
        raise FileNotFoundError(f"macos directory does not exist: {macos_dir}")
    logger.info("macos directory found: %s", macos_dir)
    return macos_dir


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


def create_layout_name(
    keylayout: str, variant: str, use_date_in_filename: bool
) -> tuple[str, str]:
    """
    Generate the layout id and display name from the variant and optionally the date.

    Args:
        variant (str): The layout variant name.
        use_date_in_filename (bool): Whether to append the date to the output.

    Returns:
        tuple[str, str]: (layout_id, layout_name)
    """
    layout_id = variant.replace(
        ".", "_"
    )  # If there are dots in the id (here in version number), the layout doesn't work
    layout_name = "France - " + extract_name_from_file(keylayout)

    if use_date_in_filename:
        now = datetime.datetime.now()
        layout_id += f"_{now.year}_{now.month:02d}_{now.day:02d}_{now.hour:02d}h{now.minute:02d}"
        layout_name += f" {now.year}/{now.month:02d}/{now.day:02d} {now.hour:02d}:{now.minute:02d}"

    return layout_id, layout_name


if __name__ == "__main__":
    main(use_date_in_filename=False)
