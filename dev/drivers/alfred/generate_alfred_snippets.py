#!/usr/bin/env python3
"""
Script to generate Alfred snippets from TOML hotstrings files.

This script creates .alfredsnippets files (ZIP archives) for each TOML file
in the hotstrings directory. It handles symbol extraction from triggers
(★, $) and places them in the info.plist as prefix/suffix.

Official Alfred documentation about snippets can be found at:
https://www.alfredapp.com/help/features/snippets/
"""

import json
import re
import sys
import tempfile
import uuid
import zipfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.append(str(Path(__file__).resolve().parent.parent))

from utilities.logger import get_error_count, logger, reset_error_count
from utilities.mappings_functions import (
    generate_case_variants_for_trigger_replacement,
)


def main(
    input_directory: Optional[Path] = None,
    output_directory: Optional[Path] = None,
    overwrite: bool = False,
) -> None:
    """
    Main function to generate Alfred snippets from TOML hotstrings files.

    Args:
        input_directory: Directory containing TOML files. If None, uses default config directory.
        output_directory: Directory to save .alfredsnippets files. If None, uses current directory.
        overwrite: Whether to overwrite existing files.
    """
    reset_error_count()

    logger.info("=" * 80)
    logger.info("🔮 Alfred Snippets Generator")
    logger.info("=" * 80)

    # Determine directories
    if input_directory:
        config_directory = Path(input_directory).resolve()
    else:
        config_directory = Path(__file__).resolve().parent.parent / "hotstrings"

    if output_directory:
        output_directory = Path(output_directory).resolve()
    else:
        output_directory = Path(__file__).resolve().parent / "snippets"
        output_directory.mkdir(parents=True, exist_ok=True)

    logger.info("Input directory: %s", config_directory)
    logger.info("Output directory: %s", output_directory)

    # Find all TOML files recursively and filter out magic_sample
    toml_files = []

    def find_toml_files_recursive(directory: Path, relative_path: str = ""):
        """Recursively find all TOML files and their relative paths."""
        try:
            for item in directory.iterdir():
                if (
                    item.is_file()
                    and item.suffix == ".toml"
                    and item.stem != "magic_sample"
                ):
                    toml_files.append((item, relative_path))
                elif item.is_dir():
                    new_relative_path = (
                        relative_path + "/" + item.name
                        if relative_path
                        else item.name
                    )
                    find_toml_files_recursive(item, new_relative_path)
        except PermissionError:
            logger.warning(
                "Permission denied accessing directory: %s", directory
            )

    find_toml_files_recursive(config_directory)

    if not toml_files:
        logger.error("No TOML files found in: %s", config_directory)
        return

    logger.info("Found %d TOML file(s) to process", len(toml_files))

    processed = 0
    errors = 0

    for toml_file, relative_path in toml_files:
        display_name = toml_file.name
        if relative_path:
            display_name = f"{toml_file.name} in {relative_path}/"

        logger.launch("Processing: %s", display_name)
        try:
            # Create output directory with preserved structure
            output_subdir = (
                output_directory / relative_path
                if relative_path
                else output_directory
            )
            output_subdir.mkdir(parents=True, exist_ok=True)

            generate_alfred_snippets_from_toml(
                toml_file, output_subdir, overwrite
            )
            processed += 1
            logger.success("Successfully processed: %s", display_name)
        except (OSError, ValueError, RuntimeError) as e:
            logger.error("Error processing %s: %s", display_name, e)
            errors += 1

    show_execution_summary(processed, errors)


def generate_uuid() -> str:
    """
    Generate a UUID in uppercase format matching Alfred's convention.

    Returns:
        UUID string in uppercase format.
    """
    return str(uuid.uuid4()).upper()


def parse_toml_simple(toml_content: str) -> Dict[str, Dict[str, any]]:
    """
    Parse TOML content to extract trigger-replacement mappings with metadata.

    Args:
        toml_content: TOML file content as string

    Returns:
        Dictionary mapping triggers to dictionaries containing output, is_word, auto_expand
    """
    result = {}
    for line in toml_content.split("\n"):
        line = line.strip()
        if line.startswith("#") or not line or line.startswith("["):
            continue

        # New format: "trigger" = { output = "replacement", is_word = true/false, auto_expand = true/false }
        match = re.match(
            r'^"([^"]+)"\s*=\s*\{\s*output\s*=\s*"([^"]+)",\s*is_word\s*=\s*(true|false),\s*auto_expand\s*=\s*(true|false)\s*\}',
            line,
        )
        if match:
            trigger = match.group(1)
            output = match.group(2)
            is_word = match.group(3) == "true"
            auto_expand = match.group(4) == "true"
            # Only add if trigger doesn't already exist (keep first occurrence)
            if trigger not in result:
                result[trigger] = {
                    "output": output,
                    "is_word": is_word,
                    "auto_expand": auto_expand,
                }
            else:
                logger.warning(
                    "Duplicate trigger found and ignored: '%s'", trigger
                )
        else:
            # Fallback for old format: "trigger" = "replacement"
            old_match = re.match(r'^"([^"]+)"\s*=\s*"([^"]+)"', line)
            if old_match:
                trigger = old_match.group(1)
                output = old_match.group(2)
                # Only add if trigger doesn't already exist (keep first occurrence)
                if trigger not in result:
                    result[trigger] = {
                        "output": output,
                        "is_word": False,
                        "auto_expand": True,  # Default to true for backward compatibility
                    }
                else:
                    logger.warning(
                        "Duplicate trigger found and ignored: '%s'", trigger
                    )
    return result


def detect_trigger_symbols(triggers: List[str]) -> Tuple[str, str]:
    """
    Detect common prefix and suffix symbols in triggers.

    Args:
        triggers: List of trigger strings

    Returns:
        Tuple of (prefix, suffix) symbols to extract
    """
    if not triggers:
        return "", ""

    first_trigger = triggers[0]
    prefix = ""
    suffix = ""

    # Detect common suffixes (★, $, etc.)
    if first_trigger.endswith("★"):
        suffix = "★"
    elif first_trigger.endswith("$"):
        suffix = "$"

    # Detect common prefixes (could be extended)
    # For now, focus on suffixes as mentioned in requirements

    return prefix, suffix


def clean_triggers(
    triggers_dict: Dict[str, Dict[str, any]],
) -> Tuple[Dict[str, Dict[str, any]], str, str]:
    """
    Clean triggers by removing detected symbols and return them.

    Args:
        triggers_dict: Dictionary of trigger -> metadata mappings

    Returns:
        Tuple of (cleaned_dict, prefix, suffix)
    """
    triggers_list = list(triggers_dict.keys())
    prefix, suffix = detect_trigger_symbols(triggers_list)

    cleaned_dict = {}
    for trigger, metadata in triggers_dict.items():
        clean_trigger = trigger
        if prefix and clean_trigger.startswith(prefix):
            clean_trigger = clean_trigger[len(prefix) :]
        if suffix and clean_trigger.endswith(suffix):
            clean_trigger = clean_trigger[: -len(suffix)]
        cleaned_dict[clean_trigger] = metadata

    return cleaned_dict, prefix, suffix


def create_snippet_json(
    trigger: str, result: str, uid: str, auto_expand: bool = True
) -> Dict:
    """
    Create a snippet JSON structure for Alfred.

    Args:
        trigger: The trigger keyword
        result: The replacement text
        uid: Unique identifier for the snippet
        auto_expand: Whether the snippet should auto-expand

    Returns:
        Dictionary representing the snippet JSON structure
    """
    snippet_data = {
        "alfredsnippet": {
            "uid": uid,
            "name": f"{trigger} ➜ {result}",
            "keyword": trigger,
            "snippet": result,
            # Always include dontautoexpand field
            "dontautoexpand": not auto_expand,
        }
    }

    return snippet_data


def create_info_plist(prefix: str = "", suffix: str = "") -> str:
    """
    Create the info.plist content for Alfred snippets.

    Args:
        prefix: The prefix to add before snippet keywords
        suffix: The suffix to add after snippet keywords

    Returns:
            The XML content for info.plist
    """
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>snippetkeywordprefix</key>
	<string>{prefix}</string>
	<key>snippetkeywordsuffix</key>
	<string>{suffix}</string>
</dict>
</plist>"""


def create_alfredsnippets_file(
    output_path: Path,
    snippets_data: List[Dict],
    collection_name: str,
    prefix: str = "",
    suffix: str = "",
) -> None:
    """
    Create a .alfredsnippets file (ZIP archive) from snippets data.

    Args:
        output_path: Directory where to create the .alfredsnippets file
        snippets_data: List of snippet data dictionaries
        collection_name: Name of the collection (used for filename)
        prefix: Prefix for snippet keywords
        suffix: Suffix for snippet keywords

    Raises:
            OSError: If there's an error creating files or directories
    """
    logger.info(
        "Creating %s.alfredsnippets with %d snippets",
        collection_name,
        len(snippets_data),
    )

    # Create a temporary directory
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)

        # Create info.plist with custom prefix and suffix
        info_plist_path = temp_path / "info.plist"
        try:
            with open(info_plist_path, "w", encoding="utf-8") as f:
                f.write(create_info_plist(prefix, suffix))
        except OSError as e:
            raise OSError(f"Error creating info.plist: {e}")

        # Create JSON files for each snippet
        for snippet_data in snippets_data:
            uid = snippet_data["alfredsnippet"]["uid"]
            json_file = temp_path / f"{uid}.json"
            try:
                with open(json_file, "w", encoding="utf-8") as f:
                    json.dump(snippet_data, f, indent=2, ensure_ascii=False)
            except OSError as e:
                raise OSError(f"Error creating snippet file {uid}.json: {e}")

        # Create ZIP archive with .alfredsnippets extension
        archive_path = output_path / f"{collection_name}.alfredsnippets"
        try:
            with zipfile.ZipFile(
                archive_path, "w", zipfile.ZIP_DEFLATED
            ) as zipf:
                # Add all files from temp directory
                for file_path in temp_path.rglob("*"):
                    if file_path.is_file():
                        # Use relative path within the archive
                        arcname = file_path.relative_to(temp_path)
                        zipf.write(file_path, arcname)
        except OSError as e:
            raise OSError(f"Error creating archive {archive_path}: {e}")

    logger.info("Created %s with %d snippets", archive_path, len(snippets_data))


def generate_alfred_snippets_from_toml(
    toml_file: Path,
    output_directory: Path,
    overwrite: bool = False,
) -> None:
    """
    Generate Alfred snippets from a single TOML file.

    Args:
        toml_file: Path to the TOML file to process
        output_directory: Directory to save the .alfredsnippets file
        overwrite: Whether to overwrite existing files

    Raises:
        FileNotFoundError: If the TOML file doesn't exist
        ValueError: If the TOML file is empty or malformed
        OSError: If there's an error reading the file or writing output
    """
    if not toml_file.exists():
        raise FileNotFoundError(f"TOML file not found: {toml_file}")

    # Read TOML file
    try:
        toml_content = toml_file.read_text(encoding="utf-8")
    except OSError as e:
        raise OSError(f"Error reading TOML file {toml_file}: {e}")

    if not toml_content.strip():
        raise ValueError(f"TOML file is empty: {toml_file}")

    # Parse TOML content
    triggers_dict = parse_toml_simple(toml_content)
    if not triggers_dict:
        raise ValueError(f"No valid triggers found in TOML file: {toml_file}")

    # Clean triggers and detect symbols
    cleaned_dict, prefix, suffix = clean_triggers(triggers_dict)
    logger.info("Detected prefix: '%s', suffix: '%s'", prefix, suffix)

    # Generate snippets data
    snippets_data = []
    all_triggers_seen = set()  # Track all triggers across all variants

    for trigger, metadata in cleaned_dict.items():
        replacement = metadata["output"]
        auto_expand = metadata["auto_expand"]

        # Generate case variants
        variants = generate_case_variants_for_trigger_replacement(
            trigger, replacement
        )

        for variant_trigger, variant_replacement in variants:
            # Check for duplicates across all snippets
            if variant_trigger not in all_triggers_seen:
                uid = generate_uuid()
                snippet_data = create_snippet_json(
                    variant_trigger, variant_replacement, uid, auto_expand
                )
                snippets_data.append(snippet_data)
                all_triggers_seen.add(variant_trigger)
            else:
                logger.warning(
                    "Duplicate trigger across variants found and ignored: '%s'",
                    variant_trigger,
                )

    # Determine output file name
    collection_name = toml_file.stem.capitalize()
    output_file = output_directory / f"{collection_name}.alfredsnippets"

    # Check if file exists and handle overwrite
    if output_file.exists() and not overwrite:
        logger.warning("Output file already exists, skipping: %s", output_file)
        return

    # Create Alfred snippets file
    create_alfredsnippets_file(
        output_directory, snippets_data, collection_name, prefix, suffix
    )


def can_overwrite_file(file_path: Path, overwrite: bool) -> bool:
    """
    Handle deciding what to do if a file already exists.

    Args:
        file_path: Path to check for existence
        overwrite: Whether overwriting is allowed

    Returns:
        True if we proceed with overwrite or file doesn't exist, False if we skip
    """
    if file_path.exists():
        logger.warning("Destination file already exists: %s", file_path)
        if overwrite:
            logger.warning("Overwriting: %s", file_path)
            return True
        else:
            logger.warning("Skipping modification: %s", file_path)
            return False
    return True


def show_execution_summary(processed: int, errors: int) -> None:
    """
    Display a summary of the generation process.

    Args:
        processed: Number of successfully processed files
        errors: Number of errors encountered
    """
    if errors == 0 and get_error_count() == 0:
        logger.success("=" * 81)
        logger.success("=" * 81)
        logger.success("=" * 81)
        logger.success(
            "======= All files processed successfully: %d file(s) processed, no errors! =======",
            processed,
        )
        logger.success("=" * 81)
        logger.success("=" * 81)
        logger.success("=" * 81)
    else:
        logger.error("=" * 100)
        logger.error("=" * 100)
        logger.error("=" * 100)
        logger.error(
            "======= Processing complete. %d file(s) processed, %d error(s) (exceptions), %d error log(s). =======",
            processed,
            errors,
            get_error_count(),
        )
        logger.error("=" * 100)
        logger.error("=" * 100)
        logger.error("=" * 100)


if __name__ == "__main__":
    main(overwrite=True)
