#!/usr/bin/env python3
"""
Script to generate Espanso match files from TOML hotstrings files.

This script creates .yml files for each TOML file in the hotstrings directory.
It handles symbol extraction from triggers (★, $) and generates proper Espanso format
with propagate_case support.

Official Espanso documentation about matches can be found at:
https://espanso.org/docs/matches/basics/
"""

import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.append(str(Path(__file__).resolve().parent.parent))

from utilities.logger import get_error_count, logger, reset_error_count


def sort_files_by_priority(
    toml_files: List[Path], priority_order: List[str]
) -> List[Path]:
    """
    Sort TOML files according to priority order.

    Args:
        toml_files: List of Path objects to TOML files
        priority_order: List of file stems in priority order (highest to lowest)

    Returns:
        Sorted list of Path objects
    """

    def get_priority(file_path: Path) -> int:
        """Get priority index for a file, higher number = lower priority."""
        stem = file_path.stem
        try:
            return priority_order.index(stem)
        except ValueError:
            # Files not in priority list go to the end
            return len(priority_order)

    return sorted(toml_files, key=get_priority)


def main(
    input_directory: Optional[Path] = None,
    output_directory: Optional[Path] = None,
    overwrite: bool = False,
) -> None:
    """
    Main function to generate Espanso match files from TOML hotstrings files.

    Args:
            input_directory: Directory containing TOML files. If None, uses default config directory.
            output_directory: Directory to save .yml files. If None, uses espanso match directory.
            overwrite: Whether to overwrite existing files.
    """
    reset_error_count()

    logger.info("=" * 80)
    logger.info("🔧 Espanso Match Generator")
    logger.info("=" * 80)

    # Determine directories
    if input_directory:
        config_directory = Path(input_directory).resolve()
    else:
        config_directory = Path(__file__).resolve().parent.parent / "hotstrings"

    if output_directory:
        output_directory = Path(output_directory).resolve()
    else:
        output_directory = Path(__file__).resolve().parent / "match"

    logger.info("Input directory: %s", config_directory)
    logger.info("Output directory: %s", output_directory)

    # Ensure output directory exists
    try:
        output_directory.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        logger.error(
            "Error creating output directory %s: %s", output_directory, e
        )
        return

    # Find all TOML files and filter out magic_sample
    toml_files = list(config_directory.glob("*.toml"))
    # Exclude magic_sample from processing
    toml_files = [f for f in toml_files if f.stem != "magic_sample"]

    if not toml_files:
        logger.error("No TOML files found in: %s", config_directory)
        return

    # Define priority order (highest to lowest priority)
    priority_order = [
        "rolls",
        "magic",
        "suffixes",
        "symbols",
        "symbols_typst",
        "repeat",
    ]

    # Sort files by priority
    toml_files_sorted = sort_files_by_priority(toml_files, priority_order)

    logger.info("Found %d TOML file(s) to process", len(toml_files_sorted))
    logger.info(
        "Processing order (by priority): %s",
        [f.stem for f in toml_files_sorted],
    )

    # Collect all triggers to avoid duplicates
    used_triggers = set()
    processed = 0
    errors = 0

    for toml_file in toml_files_sorted:
        logger.launch("Processing: %s", toml_file.name)
        try:
            generate_espanso_match_from_toml(
                toml_file, output_directory, overwrite, used_triggers
            )
            processed += 1
            logger.success("Successfully processed: %s", toml_file.name)
        except (OSError, ValueError, RuntimeError) as e:
            logger.error("Error processing %s: %s", toml_file.name, e)
            errors += 1

    show_execution_summary(processed, errors)


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
            result[trigger] = {
                "output": output,
                "is_word": is_word,
                "auto_expand": auto_expand,
            }
        else:
            # Fallback for old format: "trigger" = "replacement"
            old_match = re.match(r'^"([^"]+)"\s*=\s*"([^"]+)"', line)
            if old_match:
                trigger = old_match.group(1)
                output = old_match.group(2)
                result[trigger] = {
                    "output": output,
                    "is_word": False,
                    "auto_expand": True,
                }
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


def escape_yaml_string(text: str) -> str:
    """
    Escape special characters in a string for YAML format.

    Args:
        text: The string to escape

    Returns:
        Escaped string suitable for YAML
    """
    # For YAML, we need to escape single quotes and handle special characters
    if "'" in text:
        return f'"{text.replace(chr(92), chr(92) + chr(92)).replace('"', chr(92) + '"')}"'
    return f"'{text}'"


def create_espanso_match_entry(
    trigger: str,
    replacement: str,
    suffix: str = "",
    use_propagate_case: bool = False,
    is_word: bool = False,
) -> str:
    """
    Create a single Espanso match entry in YAML format.

    Args:
        trigger: The trigger keyword
        replacement: The replacement text
        suffix: The suffix symbol to add to trigger (e.g., "★")
        use_propagate_case: Whether to add propagate_case: true
        is_word: Whether to add word: true

    Returns:
        YAML formatted match entry as string
    """
    full_trigger = trigger + suffix
    trigger_escaped = escape_yaml_string(full_trigger)
    replacement_escaped = escape_yaml_string(replacement)

    lines = [f"  - trigger: {trigger_escaped}"]
    lines.append(f"    replace: {replacement_escaped}")

    if use_propagate_case:
        lines.append("    propagate_case: true")

    # if is_word:
    #     lines.append("    word: true")

    return "\n".join(lines)


def remove_duplicate_triggers(
    triggers_dict: Dict[str, Dict[str, any]],
    used_triggers: set,
    suffix: str = "",
) -> Dict[str, Dict[str, any]]:
    """
    Remove triggers that are already used to avoid duplicates.

    Args:
        triggers_dict: Dictionary of trigger -> metadata mappings
        used_triggers: Set of already used full triggers (with suffix)
        suffix: The suffix to append to triggers

    Returns:
        Dictionary with duplicate triggers removed
    """
    filtered_dict = {}

    for trigger, metadata in triggers_dict.items():
        full_trigger = trigger + suffix
        if full_trigger not in used_triggers:
            filtered_dict[trigger] = metadata

    return filtered_dict


def generate_espanso_match_from_toml(
    toml_file: Path,
    output_directory: Path,
    overwrite: bool = False,
    used_triggers: Optional[set] = None,
) -> None:
    """
    Generate Espanso match file from a single TOML file.

    Args:
        toml_file: Path to the TOML file to process
        output_directory: Directory to save the .yml file
        overwrite: Whether to overwrite existing files
        used_triggers: Set of already used triggers to avoid duplicates

    Raises:
        FileNotFoundError: If the TOML file doesn't exist
        ValueError: If the TOML file is empty or malformed
        OSError: If there's an error reading the file or writing output
    """
    if used_triggers is None:
        used_triggers = set()

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

    # Remove duplicates based on used_triggers
    original_count = len(cleaned_dict)
    cleaned_dict = remove_duplicate_triggers(
        cleaned_dict, used_triggers, suffix
    )
    removed_count = original_count - len(cleaned_dict)

    if removed_count > 0:
        logger.info(
            "Removed %d duplicate trigger(s) from %s",
            removed_count,
            toml_file.name,
        )

    # Update used_triggers with current triggers
    for trigger in cleaned_dict.keys():
        full_trigger = trigger + suffix
        used_triggers.add(full_trigger)

    # Skip file generation if no triggers remain after deduplication
    if not cleaned_dict:
        logger.warning(
            "No triggers remaining after deduplication for %s, skipping file generation",
            toml_file.name,
        )
        return

    # Determine output file name
    output_file = output_directory / f"{toml_file.stem}.yml"

    # Check if file exists and handle overwrite
    if output_file.exists() and not overwrite:
        logger.warning("Output file already exists, skipping: %s", output_file)
        return

    # Determine if this file should use propagate_case
    file_stem = toml_file.stem.lower()
    use_propagate_case = file_stem not in [
        "brands",
        "emojis",
        "punctuation",
        "symbols_typst",
        "symbols",
    ]

    # Generate YAML content
    yaml_lines = ["matches:"]

    # Sort triggers for consistent output
    for trigger in sorted(cleaned_dict.keys()):
        metadata = cleaned_dict[trigger]
        replacement = metadata["output"]
        is_word = metadata["is_word"]
        match_entry = create_espanso_match_entry(
            trigger, replacement, suffix, use_propagate_case, is_word
        )
        yaml_lines.append(match_entry)

    yaml_content = "\n".join(yaml_lines) + "\n"

    # Write YAML file
    try:
        output_file.write_text(yaml_content, encoding="utf-8")
    except OSError as e:
        raise OSError(f"Error writing YAML file {output_file}: {e}")

    logger.info(
        "Created %s with %d matches", output_file.name, len(cleaned_dict)
    )


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
