#!/usr/bin/env python3
"""
Script to extract text expansion blocks from an AutoHotkey file
and convert them to TOML format.
"""

import re
import sys
from pathlib import Path
from typing import Optional

sys.path.append(str(Path(__file__).resolve().parent.parent))

from utilities.logger import get_error_count, logger, reset_error_count


def main(ahk_file_path: Optional[Path] = None) -> None:
    """
    Main function to extract text expansion blocks from AutoHotkey files to TOML format.

    Args:
        ahk_file_path: Optional path to the AHK file. If None, automatically detects the latest version.
    """
    reset_error_count()

    # Determine source AHK file
    if ahk_file_path:
        source_file = Path(ahk_file_path).resolve()
    else:
        source_file = get_latest_ahk_file()

    if not source_file.exists():
        logger.error("Source AHK file does not exist: %s", source_file)
        return

    logger.info("=" * 80)
    logger.info("📄 AutoHotkey to TOML Extraction")
    logger.info("=" * 80)
    logger.info("Source file: %s", source_file)

    # Define extraction tasks
    extractions = [
        ("TextExpansionEmojis", "emojis"),
        ("TextExpansion", "magic"),
        ("TextExpansionSymbols", "symbols"),
        ("TextExpansionSymbolsTypst", "symbols_typst"),
        ("SuffixesA", "suffixes"),
        ("Accents", "accents"),
        ("Names", "names"),
        ("Brands", "brands"),
        ("Minus", "minus"),
        ("MultiplePunctuationMarks", "punctuation"),
        ("Errors", "errors"),
        ("TypographicApostrophe", "apostrophe"),
    ]

    processed = 0
    errors = 0

    for block_pattern, output_name in extractions:
        logger.launch(
            "Extracting block '%s' to '%s.toml'", block_pattern, output_name
        )
        try:
            extract_ahk_block_to_toml(
                str(source_file), block_pattern, output_name
            )
            processed += 1
            logger.success("Successfully extracted '%s' block", block_pattern)
        except (OSError, ValueError, RuntimeError) as e:
            logger.error("Error extracting block '%s': %s", block_pattern, e)
            errors += 1

    show_execution_summary(processed, errors)


def get_latest_ahk_file() -> Path:
    """
    Automatically detect the latest AutoHotkey file version.

    Returns:
        Path to the latest AHK file.

    Raises:
        FileNotFoundError: If no AHK file is found.
    """
    ahk_directory = Path(__file__).parent.parent / "autohotkey"

    # Look for files matching pattern ErgoptiPlus_v*.*.*.ahk
    ahk_files = list(ahk_directory.glob("ErgoptiPlus_v*.*.*.ahk"))

    if not ahk_files:
        raise FileNotFoundError(f"No AutoHotkey files found in {ahk_directory}")

    # Sort by version number and return the latest
    ahk_files.sort(key=lambda f: extract_version_tuple(f.name), reverse=True)
    latest_file = ahk_files[0]

    logger.info("Auto-detected latest AHK file: %s", latest_file.name)
    return latest_file


def extract_version_tuple(filename: str) -> tuple[int, int, int]:
    """
    Extract version tuple from filename for sorting.

    Args:
        filename: The filename containing version info.

    Returns:
        Tuple of (major, minor, patch) version numbers.
    """
    match = re.search(r"v(\d+)\.(\d+)\.(\d+)", filename)
    if match:
        return (int(match.group(1)), int(match.group(2)), int(match.group(3)))
    return (0, 0, 0)


def extract_ahk_block_to_toml(
    ahk_file_path: str, block_pattern: str, output_name: str
) -> None:
    """
    Extract a specific block from an AutoHotkey file and convert it to TOML format.

    Args:
        ahk_file_path: Path to the source .ahk file
        block_pattern: Pattern of the block to extract (e.g., 'TextExpansionEmojis')
        output_name: Output filename without extension (e.g., 'emojis')

    Raises:
        FileNotFoundError: If the source file doesn't exist
        ValueError: If the block pattern is not found
        OSError: If there's an error writing the output file
    """
    # Determine output file path
    output_dir = Path(__file__).parent
    output_file = output_dir / f"{output_name}.toml"

    # Read the AutoHotkey file
    try:
        with open(ahk_file_path, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        raise FileNotFoundError(f"Source file not found: {ahk_file_path}")
    except OSError as e:
        raise OSError(f"Error reading file {ahk_file_path}: {e}")

    # Extract block content using robust brace matching
    block_content = extract_block_content(content, block_pattern)

    if not block_content:
        raise ValueError(
            f"Block '{block_pattern}' not found in {ahk_file_path}"
        )

    # Extract hotstrings from block content
    hotstrings = extract_hotstrings(block_content)

    if not hotstrings:
        logger.warning("No hotstrings found in block '%s'", block_pattern)

    # Convert to TOML format
    toml_content = convert_to_toml(hotstrings, block_pattern)

    # Write the TOML file
    try:
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(toml_content)

        total_entries = sum(len(entries) for entries in hotstrings.values())
        logger.info(
            "TOML file created: %s (%d entries)",
            output_file.name,
            total_entries,
        )

    except OSError as e:
        raise OSError(f"Error writing file {output_file}: {e}")


def extract_block_content(content: str, block_pattern: str) -> str:
    """
    Extract block content using robust brace matching to handle nested braces.

    Args:
        content: The full AutoHotkey file content
        block_pattern: The block pattern to search for

    Returns:
        The extracted block content, or empty string if not found
    """
    # General pattern to match any Features[...][block_pattern].Enabled block
    start_pattern = (
        rf'if Features\["[^"]+"\]\["{block_pattern}"\]\.Enabled\s*\{{'
    )
    start_match = re.search(start_pattern, content)

    if not start_match:
        return ""

    # Find the matching closing brace using brace counting
    start_idx = start_match.end()
    brace_count = 1
    end_idx = start_idx

    while end_idx < len(content) and brace_count > 0:
        if content[end_idx] == "{":
            brace_count += 1
        elif content[end_idx] == "}":
            brace_count -= 1
        end_idx += 1

    return content[start_idx : end_idx - 1] if brace_count == 0 else ""


def extract_hotstrings(
    block_content: str,
) -> dict[str, list[tuple[str, str, bool, bool]]]:
    """
    Extract hotstrings from an AutoHotkey block content.

    Args:
        block_content: The AutoHotkey block content to parse

    Returns:
        Dictionary mapping section names to lists of (trigger, output, is_word, auto_expand) tuples
    """
    hotstrings: dict[str, list[tuple[str, str, bool, bool]]] = {}
    current_section = "general"

    lines = block_content.split("\n")
    i = 0

    while i < len(lines):
        line = lines[i].strip()

        # Detect section headers (comments === Section ===)
        section_match = re.match(r";\s*===\s*(.+?)\s*===", line)
        if section_match:
            section_name = section_match.group(1).lower()
            # Clean section name for TOML compatibility
            section_name = re.sub(r"[^a-z0-9_]", "_", section_name)
            section_name = re.sub(r"_+", "_", section_name).strip("_")
            current_section = section_name
            if current_section not in hotstrings:
                hotstrings[current_section] = []
            i += 1
            continue

        # Skip comments and empty lines
        if line.startswith(";") or not line:
            i += 1
            continue

        # Check if this is the start of a multi-line CreateCaseSensitiveHotstrings or CreateHotstring call
        is_multiline = False
        if (
            (
                "CreateCaseSensitiveHotstrings(" in line
                or "CreateHotstring(" in line
            )
            and not line.rstrip().endswith(")")
            and not line.split(";")[0].rstrip().endswith(")")
        ):
            # Collect multi-line statement
            full_line = line
            j = i + 1
            while (
                j < len(lines)
                and not full_line.rstrip().endswith(")")
                and not full_line.split(";")[0].rstrip().endswith(")")
            ):
                full_line += " " + lines[j].strip()
                j += 1
            i = j  # Skip processed lines
            line = full_line
            is_multiline = True

        # Extract hotstrings using multiple patterns to cover all cases
        trigger, output, is_word, auto_expand = extract_hotstring_from_line(
            line
        )
        if trigger and output:
            # Initialize section if it doesn't exist
            if current_section not in hotstrings:
                hotstrings[current_section] = []
            hotstrings[current_section].append(
                (trigger, output, is_word, auto_expand)
            )
            logger.debug(
                "Extracted: section='%s', trigger='%s', output='%s'",
                current_section,
                trigger,
                output,
            )
        else:
            # Log lines that weren't extracted
            if (
                "CreateCaseSensitiveHotstrings(" in line
                or "CreateHotstring(" in line
                or "Hotstring" in line
            ):
                logger.warning(
                    "Failed to extract from line: %s",
                    line[:100] + "..." if len(line) > 100 else line,
                )

        # Move to next line (only if we didn't already do it in multi-line processing)
        if not is_multiline:
            i += 1

    return hotstrings


def extract_hotstring_from_line(
    line: str,
) -> tuple[Optional[str], Optional[str], bool, bool]:
    """
    Extract trigger and output from a single AutoHotkey line.

    Args:
            line: The AutoHotkey line to parse

    Returns:
            Tuple of (trigger, output, is_word, auto_expand) or (None, None, False, False) if no match
    """
    # First, try to match new CreateHotstring format
    # Updated regex to handle escaped quotes in output like "`"" and trigger concatenation
    create_hotstring_pattern = (
        r"CreateHotstring\s*\(\s*"
        r'"([^"]*)",\s*'  # Options group 1
        r'"([^"]+)"(?:\s*\.\s*ScriptInformation\["MagicKey"\])?,\s*'  # Trigger group 2 - handles concatenation with MagicKey
        r'"((?:[^"\\]|\\.|`")*)"'  # Output group 3 - handles escaped quotes and backtick-quote combinations
        r".*?"  # Match anything after the output (including Map parameters)
        r"\)"
    )

    create_hotstring_match = re.search(
        create_hotstring_pattern, line, re.DOTALL
    )

    if create_hotstring_match:
        options, trigger, output = create_hotstring_match.groups()

        # Determine auto_expand and is_word based on options
        auto_expand = "*" in options
        is_word = "?" not in options

        # Handle special case where trigger contains ScriptInformation["MagicKey"]
        if 'ScriptInformation["MagicKey"]' in line:
            trigger += "★"

        logger.debug(
            "Found CreateHotstring: trigger='%s', options='%s', auto_expand=%s, is_word=%s",
            trigger,
            options,
            auto_expand,
            is_word,
        )

        return trigger, output, is_word, auto_expand

    # Second, try to match CreateCaseSensitiveHotstrings format
    create_pattern = (
        r"CreateCaseSensitiveHotstrings\s*\(\s*"
        r'"([^"]*)",\s*'  # Options group 1
        r'"([^"]+)"(?:\s*\.\s*ScriptInformation\["MagicKey"\])?,\s*'  # Trigger group 2 - handles concatenation with MagicKey
        r'"([^"]+)"'  # Output group 3
        r".*?"  # Match anything after the output (including Map parameters)
        r"\)"
    )

    create_match = re.search(create_pattern, line, re.DOTALL)

    if create_match:
        options, trigger, output = create_match.groups()

        # Determine auto_expand and is_word based on options
        auto_expand = "*" in options
        is_word = "?" not in options

        # Handle special case where trigger contains ScriptInformation["MagicKey"]
        if 'ScriptInformation["MagicKey"]' in line:
            trigger += "★"

        logger.debug(
            "Found CreateCaseSensitiveHotstrings: trigger='%s', options='%s', auto_expand=%s, is_word=%s",
            trigger,
            options,
            auto_expand,
            is_word,
        )

        return trigger, output, is_word, auto_expand

    # Fallback to original Hotstring format
    hotstring_pattern = (
        r"Hotstring[s]?\s*\("
        r'(?:\s*"([^"]+)",)?'  # Optional options group 1
        r'\s*"([^"]+?)"'  # Trigger group 2
        r'(?:\s*\.\s*ScriptInformation\["MagicKey"\])?'
        r'\s*,\s*"([^"]+?)"'  # Output group 3
        r"\s*\)"
    )

    hotstring_match = re.search(hotstring_pattern, line, re.DOTALL)

    if hotstring_match:
        options, trigger, output = hotstring_match.groups()

        is_word = True  # Default to True, meaning it's a whole word trigger
        auto_expand = False  # Default for Hotstring format

        if options and "?" in options:
            is_word = False  # Set to False if it can be triggered inside a word

        if options and "*" in options:
            auto_expand = True

        if 'ScriptInformation["MagicKey"]' in line:
            trigger += "★"

        logger.debug(
            "Found Hotstring: trigger='%s', options='%s', auto_expand=%s, is_word=%s",
            trigger,
            options,
            auto_expand,
            is_word,
        )

        return trigger, output, is_word, auto_expand

    return None, None, False, False


def convert_to_toml(
    hotstrings: dict[str, list[tuple[str, str, bool, bool]]], block_name: str
) -> str:
    """
    Convert hotstrings dictionary to TOML format.

    Args:
        hotstrings: Dictionary mapping section names to lists of (trigger, output, is_word, auto_expand) tuples
        block_name: Name of the original block (used for header comment)

    Returns:
            Formatted TOML content as string
    """
    # Mutualized header for all TOML files
    header_lines = [
        "# DO NOT EDIT THIS FILE DIRECTLY.",
        "# This file is automatically generated. Any manual changes will be overwritten.",
        "# Format: [[section]]",
        '# All entries use: trigger = { output = "replacement", is_word = true/false, auto_expand = true/false }',
        "",
    ]

    # Special case for suffixes.toml: format [a_grave_suffixes] avec entrées fixes
    if block_name == "SuffixesA":
        toml_lines = header_lines + [
            "[a_grave_suffixes]",
            "# SFBs with BU and IÉ",
            '"àj" = "bu"',
            '"à★" = "bu"',
            '"àu" = "ub"',
            '"àé" = "éi"',
            "# Common suffixes",
        ]
        triggers_fixes = {"àj", "à★", "àu", "àé"}
        for section_name, entries in hotstrings.items():
            for trigger, output, is_word, auto_expand in entries:
                if trigger in triggers_fixes:
                    continue
                trigger_escaped = escape_toml_string(
                    trigger, escape_backslashes=False
                )
                output_escaped = escape_toml_string(
                    output, escape_backslashes=True
                )

                # Always use complex format for suffixes to include all options
                toml_lines.append(
                    f'"{trigger_escaped}" = {{ output = "{output_escaped}", is_word = {str(is_word).lower()}, auto_expand = {str(auto_expand).lower()} }}'
                )
        return "\n".join(toml_lines)

    # Cas général
    toml_lines = header_lines.copy()
    for section_name, entries in hotstrings.items():
        if not entries:
            continue
        toml_lines.append(f"[[{section_name}]]")
        for trigger, output, is_word, auto_expand in entries:
            trigger_escaped = escape_toml_string(
                trigger, escape_backslashes=False
            )
            output_escaped = escape_toml_string(output, escape_backslashes=True)

            # Always use complex format for all entries
            toml_lines.append(
                f'"{trigger_escaped}" = {{ output = "{output_escaped}", is_word = {str(is_word).lower()}, auto_expand = {str(auto_expand).lower()} }}'
            )
        toml_lines.append("")
    return "\n".join(toml_lines)


def escape_toml_string(text: str, escape_backslashes: bool = True) -> str:
    """
    Escape special characters in a string for TOML format.

    Args:
        text: The string to escape
        escape_backslashes: Whether to escape backslashes (needed for output, not triggers)

    Returns:
            Escaped string suitable for TOML
    """
    if escape_backslashes:
        text = text.replace("\\", "\\\\")
    text = text.replace('"', '\\"')
    return text


def show_execution_summary(processed: int, errors: int) -> None:
    """
    Display a summary of the extraction process.

    Args:
        processed: Number of successfully processed blocks
        errors: Number of errors encountered
    """
    if errors == 0 and get_error_count() == 0:
        logger.success("=" * 83)
        logger.success("=" * 83)
        logger.success("=" * 83)
        logger.success(
            "======= All blocks processed successfully: %d block(s) processed, no errors! =======",
            processed,
        )
        logger.success("=" * 83)
        logger.success("=" * 83)
        logger.success("=" * 83)
    else:
        logger.error("=" * 100)
        logger.error("=" * 100)
        logger.error("=" * 100)
        logger.error(
            "======= Processing complete. %d block(s) processed, %d error(s) (exceptions), %d error log(s). =======",
            processed,
            errors,
            get_error_count(),
        )
        logger.error("=" * 100)
        logger.error("=" * 100)
        logger.error("=" * 100)


if __name__ == "__main__":
    main()
