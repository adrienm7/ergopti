#!/usr/bin/env python3
"""
Format, organize, and generate TOML configuration files.

Features:
- Adds styled section headers following copilot-instructions.md
- Sorts sections alphabetically (preserves nesting level)
- Sorts keys within each section alphabetically
- Handles nested sections [section.subsection] and arrays [[array]]
- Generates TOML from JSON/Python dict input (for Hammerspoon/AHK integration)

Usage:
  Format existing TOML:
    python3 format_toml.py <toml_file> [--preview]

  Generate TOML from JSON (Hammerspoon/AHK):
    cat data.json | python3 format_toml.py --generate <output_file>
    python3 format_toml.py --generate <output_file> --data '{"section": {"key": "value"}}'
"""

import json
import re
import sys
from collections import OrderedDict
from pathlib import Path


def count_equals_needed(text: str, is_subsection: bool = False) -> int:
    """Calculate the number of = needed for a header to match the total title length."""
    side_equals = 5 if is_subsection else 7
    return side_equals + 1 + len(text) + 1 + side_equals


def create_header_line(equals_count: int) -> str:
    """Create a header line with the specified number of = characters."""
    return "# " + "=" * equals_count


def create_section_header(
    section_name: str, is_subsection: bool = False, is_first: bool = False
) -> str:
    """Create a styled section header."""
    # Strip leading/trailing whitespace from section_name FIRST to avoid double spaces
    section_name = section_name.strip()

    side_equals = 5 if is_subsection else 7
    equals_str = "=" * side_equals
    total_equals = count_equals_needed(section_name, is_subsection)
    header_footer = create_header_line(total_equals)

    title_line = f"# {equals_str} {section_name} {equals_str}"

    # Before h2: 6 blank lines (7 with join newline = 7 total visible blank lines)
    # Before h3: 0 blank lines (1 with join newline = 1 visible blank line)
    blanks = 0 if is_subsection else 6
    blank_lines = "\n" * blanks if (not is_first and blanks > 0) else ""

    if is_subsection:
        return f"{blank_lines}{header_footer}\n{title_line}\n{header_footer}"
    else:
        return f"{blank_lines}{header_footer}\n{header_footer}\n{title_line}\n{header_footer}\n{header_footer}"


def parse_toml_structure(content: str) -> dict:
    """Parse TOML content into a structured format."""
    lines = content.split("\n")
    structure = OrderedDict()
    current_section = None
    current_array = None
    current_array_index = -1

    # Strip leading empty lines
    start_idx = 0
    for i, line in enumerate(lines):
        if line.strip():
            start_idx = i
            break

    for i in range(start_idx, len(lines)):
        line = lines[i]
        stripped = line.strip()

        # Skip empty lines and comments
        if not stripped or stripped.startswith("#"):
            continue

        # Match section headers [section] or [section.subsection]
        section_match = re.match(r"^\[([^\]]+)\]$", stripped)
        if section_match:
            current_section = section_match.group(1)
            current_array = None
            current_array_index = -1
            if current_section not in structure:
                structure[current_section] = OrderedDict()
            continue

        # Match array headers [[array]]
        array_match = re.match(r"^\[\[([^\]]+)\]\]$", stripped)
        if array_match:
            current_array = array_match.group(1)
            current_section = None
            if current_array not in structure:
                structure[current_array] = []
            structure[current_array].append(OrderedDict())
            current_array_index = len(structure[current_array]) - 1
            continue

        # Parse key = value pairs
        if "=" in line and not stripped.startswith("#"):
            if current_section is not None:
                key_match = re.match(r"^([^=]+)=(.+)$", stripped)
                if key_match:
                    key = key_match.group(1).strip()
                    value = key_match.group(2).strip()
                    structure[current_section][key] = value
            elif current_array is not None and current_array_index >= 0:
                key_match = re.match(r"^([^=]+)=(.+)$", stripped)
                if key_match:
                    key = key_match.group(1).strip()
                    value = key_match.group(2).strip()
                    structure[current_array][current_array_index][key] = value

    return structure


def sort_toml_structure(structure: dict) -> dict:
    """Sort sections and keys alphabetically, preserving structure."""
    sorted_structure = OrderedDict()

    section_keys = sorted(structure.keys())

    for section_key in section_keys:
        section_content = structure[section_key]

        if isinstance(section_content, dict):
            sorted_content = OrderedDict(sorted(section_content.items()))
            sorted_structure[section_key] = sorted_content
        elif isinstance(section_content, list):
            sorted_items = []
            for item in section_content:
                if isinstance(item, dict):
                    sorted_item = OrderedDict(sorted(item.items()))
                    sorted_items.append(sorted_item)
                else:
                    sorted_items.append(item)
            sorted_structure[section_key] = sorted_items

    return sorted_structure


def rebuild_toml_from_structure(structure: dict) -> str:
    """Rebuild TOML content from sorted structure with headers."""
    lines = []
    is_first = True

    for section_key in structure.keys():
        section_content = structure[section_key]

        parts = section_key.split(".")
        depth = len(parts)
        is_subsection = depth > 1

        display_name = section_key.replace("_", " ").title()
        header = create_section_header(display_name, is_subsection, is_first=is_first)
        lines.append(header)
        is_first = False

        if isinstance(section_content, dict):
            lines.append(f"[{section_key}]")
            for key, value in sorted(section_content.items()):
                lines.append(f"{key} = {value}")
        elif isinstance(section_content, list):
            for item in section_content:
                lines.append(f"[[{section_key}]]")
                if isinstance(item, dict):
                    for key, value in sorted(item.items()):
                        lines.append(f"{key} = {value}")

        lines.append("")

    return "\n".join(lines)


def format_toml(content: str) -> str:
    """Format and organize TOML content."""
    structure = parse_toml_structure(content)
    sorted_structure = sort_toml_structure(structure)
    formatted = rebuild_toml_from_structure(sorted_structure)
    return formatted


def value_to_toml_repr(value) -> str:
    """Convert Python value to TOML representation."""
    if isinstance(value, bool):
        return "true" if value else "false"
    elif isinstance(value, (int, float)):
        return str(value)
    elif isinstance(value, str):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    elif isinstance(value, list):
        items = [value_to_toml_repr(v) for v in value]
        return "[" + ", ".join(items) + "]"
    elif isinstance(value, dict):
        items = [f"{k} = {value_to_toml_repr(v)}" for k, v in value.items()]
        return "{" + ", ".join(items) + "}"
    else:
        return str(value)


def dict_to_toml(data: dict) -> str:
    """Convert a Python dict to formatted TOML string."""
    is_first = True
    lines = []

    for section_key in sorted(data.keys()):
        section_content = data[section_key]

        parts = section_key.split(".")
        depth = len(parts)
        is_subsection = depth > 1

        display_name = section_key.replace("_", " ").title()
        header = create_section_header(display_name, is_subsection, is_first=is_first)
        lines.append(header)
        is_first = False

        lines.append(f"[{section_key}]")

        if isinstance(section_content, dict):
            for key, value in sorted(section_content.items()):
                toml_value = value_to_toml_repr(value)
                lines.append(f"{key} = {toml_value}")
        elif isinstance(section_content, list):
            for item in section_content:
                lines.append(f"[[{section_key}]]")
                if isinstance(item, dict):
                    for key, value in sorted(item.items()):
                        toml_value = value_to_toml_repr(value)
                        lines.append(f"{key} = {toml_value}")

        lines.append("")

    return "\n".join(lines)


def print_usage():
    print("Usage: format_toml.py <toml_file> [--preview]")
    print("       format_toml.py --generate <output_file> [--data JSON_STRING]")
    print("\nFormat existing TOML files:")
    print("- Adds styled section headers")
    print("- Sorts sections and keys alphabetically")
    print("- Use --preview to show output without modifying the file")
    print("\nGenerate TOML from JSON (for Hammerspoon/AHK integration):")
    print(
        "- Read JSON from stdin: cat data.json | format_toml.py --generate output.toml"
    )
    print("- Or pass inline: format_toml.py --generate output.toml --data '{...}'")


def format_mode():
    """Format existing TOML file."""
    toml_path = Path(sys.argv[1])
    preview_mode = "--preview" in sys.argv

    if not toml_path.exists():
        print(f"Error: File not found: {toml_path}")
        sys.exit(1)

    with open(toml_path, "r", encoding="utf-8") as f:
        original_content = f.read()

    formatted_content = format_toml(original_content)

    if preview_mode:
        print(formatted_content)
        print("\n" + "=" * 70)
        print("Preview mode: no changes written to disk")
    else:
        with open(toml_path, "w", encoding="utf-8") as f:
            f.write(formatted_content)
        print(f"✓ Formatted: {toml_path}")


def generate_mode():
    """Generate TOML from JSON input."""
    try:
        output_idx = sys.argv.index("--generate")
        if output_idx + 1 >= len(sys.argv):
            print("Error: --generate requires an output file path")
            print_usage()
            sys.exit(1)

        output_file = sys.argv[output_idx + 1]
        output_path = Path(output_file)

        # Check for --data flag
        data_idx = -1
        try:
            data_idx = sys.argv.index("--data")
        except ValueError:
            pass

        if data_idx >= 0 and data_idx + 1 < len(sys.argv):
            json_str = sys.argv[data_idx + 1]
            try:
                data = json.loads(json_str)
            except json.JSONDecodeError as e:
                print(f"Error parsing JSON from --data: {e}")
                sys.exit(1)
        else:
            try:
                json_input = sys.stdin.read()
                if not json_input.strip():
                    print("Error: No JSON input provided (stdin is empty)")
                    print("Provide JSON via stdin or use --data flag")
                    print_usage()
                    sys.exit(1)
                data = json.loads(json_input)
            except json.JSONDecodeError as e:
                print(f"Error parsing JSON from stdin: {e}")
                sys.exit(1)

        toml_content = dict_to_toml(data)

        with open(output_path, "w", encoding="utf-8") as f:
            f.write(toml_content)
        print(f"✓ Generated: {output_path}")

    except Exception as e:
        print(f"Error in generate mode: {e}")
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print_usage()
        sys.exit(1)

    if "--generate" in sys.argv:
        generate_mode()
    else:
        format_mode()


if __name__ == "__main__":
    main()
