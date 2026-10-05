#!/usr/bin/env python3
"""
Format, organize, and generate TOML configuration files.

Features:
- Adds styled section headers following copilot-instructions.md
- Sorts sections alphabetically (preserves nesting level)
- Sorts keys within each section alphabetically
- Handles nested sections [section.subsection] and arrays [[array]]
- Generates TOML from JSON/Python dict input (for Hammerspoon/AHK integration)
- Hotstring mode: locale-aware French sort (é/è/ê grouped with e, not after z)
- Ordered hotstrings: a header directive preserves rule and array-block order
  while validating TOML syntax and normalizing rule layout (Python 3.11+).

Usage:
  Format existing TOML (generic):
    python3 format_toml.py <toml_file> [--preview]

  Sort hotstring TOML files (locale-aware):
    python3 format_toml.py --hotstrings <file> [--check]
    python3 format_toml.py --hotstrings --all [--check]

  Generate TOML from JSON (Hammerspoon/AHK):
    cat data.json | python3 format_toml.py --generate <output_file>
    python3 format_toml.py --generate <output_file> --data '{"section": {"key": "value"}}'
"""

import json
import re
import sys
import unicodedata
from collections import OrderedDict
from pathlib import Path

# Make tools/lib importable (repo root on sys.path) for the shared-tree SSOT.
# The script lives at tools/format_toml.py — repo root is one level up.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tools.lib.paths import shared  # noqa: E402

_ERGOPTI_HOTSTRINGS = (
    Path(__file__).resolve().parents[1] / "static/layouts/registry/ergopti/hotstrings"
)

HOTSTRING_FILES = [
    shared("modules/hotstrings", "distancesreduction.toml"),
    shared("modules/hotstrings", "autocorrection.toml"),
    shared("modules/hotstrings", "magickey.toml"),
    # Language packs (declared in _index.toml [languages]).
    shared("modules/hotstrings", "french/distancesreduction.toml"),
    shared("modules/hotstrings", "french/autocorrection.toml"),
    shared("modules/hotstrings", "french/magickey.toml"),
    # The Ergopti layout extension carries the hotstrings written for its key
    # positions (static/layouts/registry/ergopti/manifest.toml).
    _ERGOPTI_HOTSTRINGS / "sfbsreduction.toml",
    _ERGOPTI_HOTSTRINGS / "rolls.toml",
    _ERGOPTI_HOTSTRINGS / "repeatcorrections.toml",
]

_REPO_ROOT = Path(__file__).resolve().parents[1]


def section_display_name(section_key: str) -> str:
    """Build the header display name from a full dotted section key.

    Each segment has its first letter capitalised and underscores replaced with
    spaces; segments are re-joined with dots — matching the Hammerspoon style:
      hotstrings.editor.shortcut → Hotstrings.Editor.Shortcut
    """
    parts = section_key.split(".")
    formatted = []
    for p in parts:
        p = p.replace("_", " ")
        formatted.append(p[0].upper() + p[1:] if p else p)
    return ".".join(formatted)


def count_equals_needed(text: str, is_subsection: bool = False) -> int:
    """Calculate the number of = needed for a header to match the total title length."""
    side_equals = 5 if is_subsection else 7
    return side_equals + 1 + len(text) + 1 + side_equals


def create_header_line(equals_count: int) -> str:
    """Create a header line with the specified number of = characters."""
    return "# " + "=" * equals_count


def create_section_header(section_name: str, is_subsection: bool = False) -> list:
    """Create a styled section header as a list of lines (header only, no spacing)."""
    # Strip leading/trailing whitespace from section_name FIRST to avoid double spaces
    section_name = section_name.strip()

    side_equals = 5 if is_subsection else 7
    equals_str = "=" * side_equals
    total_equals = count_equals_needed(section_name, is_subsection)
    header_footer = create_header_line(total_equals)

    title_line = f"# {equals_str} {section_name} {equals_str}"

    if is_subsection:
        return [header_footer, title_line, header_footer]
    else:
        return [
            header_footer,
            header_footer,
            title_line,
            header_footer,
            header_footer,
        ]


def parse_toml_structure(content: str) -> dict:
    """Parse TOML content into a structured format."""
    # Strip UTF-8 BOM if present (written by Windows tools like AHK)
    content = content.lstrip("﻿")
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
            key_match = re.match(r"^([^=]+)=(.+)$", stripped)
            if key_match:
                key = key_match.group(1).strip()
                value = key_match.group(2).strip()
                if current_section is not None:
                    structure[current_section][key] = value
                elif current_array is not None and current_array_index >= 0:
                    structure[current_array][current_array_index][key] = value
                else:
                    # Root-level key (before any [section])
                    if "" not in structure:
                        structure[""] = OrderedDict()
                    structure[""][key] = value

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

    # Emit root-level keys first (no section header)
    if "" in structure and isinstance(structure[""], dict):
        for key, value in sorted(structure[""].items()):
            lines.append(f"{key} = {value}")
        lines.append("")
        is_first = False

    for section_key in structure.keys():
        if section_key == "":
            continue

        section_content = structure[section_key]

        parts = section_key.split(".")
        depth = len(parts)
        is_subsection = depth > 1

        # Add blank lines before header (not the first section)
        # We already have 1 blank after previous section, so we add:
        # - 4 more blanks for h2 (total 5)
        # - 2 more blanks for h3 (total 3)
        if not is_first:
            if is_subsection:
                lines.extend(["", ""])  # 2 blanks before h3 (total 3 with the one after)
            else:
                lines.extend(["", "", "", ""])  # 4 blanks before h2 (total 5 with the one after)

        display_name = section_display_name(section_key)
        header_lines = create_section_header(display_name, is_subsection)
        lines.extend(header_lines)
        lines.append("")  # blank line after header
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

        lines.append("")  # blank line after section content

    # Remove trailing blank lines (join will add the final newline)
    while lines and lines[-1] == "":
        lines.pop()

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

        # Add blank lines before header (not the first section)
        # We already have 1 blank after previous section, so we add:
        # - 4 more blanks for h2 (total 5)
        # - 2 more blanks for h3 (total 3)
        if not is_first:
            if is_subsection:
                lines.extend(["", ""])  # 2 blanks before h3 (total 3 with the one after)
            else:
                lines.extend(["", "", "", ""])  # 4 blanks before h2 (total 5 with the one after)

        display_name = section_display_name(section_key)
        header_lines = create_section_header(display_name, is_subsection)
        lines.extend(header_lines)
        lines.append("")  # blank line after header
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

        lines.append("")  # blank line after section content

    # Remove trailing blank lines (join will add the final newline)
    while lines and lines[-1] == "":
        lines.pop()

    return "\n".join(lines)


# ====================================================
# ====================================================
# ======= Hotstring sort (locale-aware, fr) =======
# ====================================================
# ====================================================

_HS_ARRAY_RE = re.compile(r"^\[\[([^\[\]]+)\]\]$")
_HS_ENTRY_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*(\{.*\})\s*$')
_HS_ORDERED_ENTRY_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*(\{.*\})(\s+#.*)?$')
_HS_ORDER_DIRECTIVE = "# format_toml: preserve-rule-order"


def _hs_preserves_rule_order(content: str) -> bool:
    """Admit the tooling directive only in the comment preamble, before TOML."""
    for line in content.splitlines():
        stripped = line.strip()
        if stripped == _HS_ORDER_DIRECTIVE:
            return True
        if stripped and not stripped.startswith("#"):
            return False
    return False


def _hs_parse_ordered(content: str) -> list[str]:
    """Validate and canonically render physical rule records without regrouping.

    Cross-family order can decide equal-priority matches. Keep every repeated
    array header and comment in place; normalize only line/rule layout. The
    metadata follows the existing hotstring formatter's verbatim-line contract.
    """
    try:
        import tomllib
    except ImportError as error:
        raise ValueError("Ordered hotstrings require Python 3.11+ for syntax admission") from error
    try:
        original_values = tomllib.loads(content)
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f"Invalid ordered hotstring TOML: {error}") from error

    lines: list[str] = []
    in_rules = False
    for number, line in enumerate(content.splitlines(), start=1):
        stripped = line.strip()
        header = _HS_ARRAY_RE.fullmatch(stripped)
        if header:
            in_rules = True
            lines.append(f"[[{header.group(1).strip()}]]")
        elif stripped.startswith("[["):
            raise ValueError(f"Unsupported ordered hotstring array header at line {number}")
        elif not in_rules or not stripped or stripped.startswith("#"):
            lines.append(line.rstrip())
        else:
            entry = _HS_ORDERED_ENTRY_RE.fullmatch(stripped)
            if entry is None:
                raise ValueError(f"Unsupported ordered hotstring record at line {number}")
            trigger, value, comment = entry.groups()
            lines.append(f'"{trigger}" = {value}' + (f" {comment.lstrip()}" if comment else ""))
    while lines and lines[-1] == "":
        lines.pop()
    # Metadata is verbatim apart from the existing line-rstrip convention.
    # That convention can touch a multiline string's meaningful spaces, so
    # refuse before publication if any normalization changed decoded values.
    if tomllib.loads("\n".join(lines) + "\n") != original_values:
        raise ValueError("Ordered hotstring formatting would change TOML values")
    return lines


def _locale_sort_key(s: str) -> tuple:
    """Return a (base, original) sort key that groups accented variants.

    NFD-decomposes the string, strips combining diacritics from the base
    used for primary ordering, so é/è/ê/ë all sort next to e rather than
    after z.  The original (case-folded) string is the tiebreaker so two
    keys differing only by accent are still ordered consistently.
    """
    nfd = unicodedata.normalize("NFD", s.casefold())
    base = "".join(c for c in nfd if unicodedata.category(c) != "Mn")
    return (base, s.casefold())


def _hs_parse(content: str) -> dict:
    """Parse a hotstring TOML into meta lines + ordered section dict.

    Returns::

        {
            "meta_lines": [...],   # verbatim lines up to first [[section]]
            "sections":   {name: [(trigger, value), ...]},
        }
    """
    if _hs_preserves_rule_order(content):
        return {"ordered_lines": _hs_parse_ordered(content)}

    lines = content.splitlines()
    meta_lines: list[str] = []
    sections: dict[str, list[tuple[str, str]]] = {}
    current: str | None = None
    in_meta = True

    for line in lines:
        stripped = line.rstrip()
        if in_meta:
            m = _HS_ARRAY_RE.match(stripped)
            if m:
                in_meta = False
                current = m.group(1)
                sections.setdefault(current, [])
                # Remove any section-header comment lines (# ===...) and
                # blank lines that _hs_rebuild injected before the first [[.
                # These must not end up in meta_lines or the second pass will
                # produce a longer meta block than the first (non-idempotent).
                while meta_lines and (meta_lines[-1] == "" or meta_lines[-1].startswith("# =")):
                    meta_lines.pop()
            else:
                meta_lines.append(stripped)
            continue
        m = _HS_ARRAY_RE.match(stripped)
        if m:
            current = m.group(1)
            sections.setdefault(current, [])
            continue
        if current is not None:
            em = _HS_ENTRY_RE.match(stripped)
            if em:
                sections[current].append((em.group(1), em.group(2)))

    return {"meta_lines": meta_lines, "sections": sections}


def _hs_rebuild(parsed: dict) -> str:
    """Reassemble the hotstring TOML with sorted sections and entries."""
    if "ordered_lines" in parsed:
        return "\n".join(parsed["ordered_lines"]) + "\n"

    out: list[str] = []

    meta = list(parsed["meta_lines"])
    while meta and meta[-1] == "":
        meta.pop()
    out.extend(meta)

    for section in sorted(parsed["sections"].keys(), key=_locale_sort_key):
        entries = sorted(
            parsed["sections"][section],
            key=lambda e: _locale_sort_key(e[0]),
        )
        out += ["", "", "", "", ""]
        out += create_section_header(section[0].upper() + section[1:])
        out.append("")
        out.append(f"[[{section}]]")
        for trigger, value in entries:
            out.append(f'"{trigger}" = {value}')

    out.append("")
    return "\n".join(out)


def sort_hotstring_file(path: Path, check: bool = False) -> bool:
    """Sort and format a hotstring TOML in-place (or check only).

    Returns True when the file was (or would be) changed.
    """
    original = path.read_text(encoding="utf-8").lstrip("﻿")
    formatted = _hs_rebuild(_hs_parse(original))
    changed = formatted != original

    rel = path.relative_to(_REPO_ROOT) if path.is_absolute() else path

    if check:
        print(f"  {'FAIL' if changed else 'ok  '}  {rel}")
        return changed

    if changed:
        # The explicit newline is not optional: on Windows the default
        # translates every line feed to CRLF, and this repo is LF-only. The
        # hotstrings hook had been calling a moved path for long enough that
        # its first working run rewrote _index.toml entirely in CRLF.
        path.write_text(formatted, encoding="utf-8", newline="\n")
        print(f"  formatted  {rel}")
    else:
        print(f"  ok         {rel}")
    return changed


def hotstrings_mode() -> None:
    """Entry point for --hotstrings mode."""
    args = sys.argv[2:]
    check = "--check" in args
    all_mode = "--all" in args
    args = [a for a in args if a not in ("--check", "--all")]

    if all_mode:
        targets = [p.resolve() for p in HOTSTRING_FILES]
    else:
        targets = [Path(a).resolve() for a in args]

    if not targets:
        print("Error: provide a file path or use --all")
        sys.exit(1)

    any_changed = False
    for target in targets:
        if not target.exists():
            print(f"  skip  {target} (not found)")
            continue
        any_changed |= sort_hotstring_file(target, check=check)

    if check and any_changed:
        print()
        print("Some hotstring files are not sorted/formatted.")
        print("Run: python3 tools/format_toml.py --hotstrings --all")
        sys.exit(1)


def print_usage():
    print("Usage: format_toml.py <toml_file> [--preview]")
    print("       format_toml.py --hotstrings <file|--all> [--check]")
    print("       format_toml.py --generate <output_file> [--data JSON_STRING]")
    print("\nFormat existing TOML files:")
    print("- Adds styled section headers")
    print("- Sorts sections and keys alphabetically")
    print("- Use --preview to show output without modifying the file")
    print("\nGenerate TOML from JSON (for Hammerspoon/AHK integration):")
    print("- Read JSON from stdin: cat data.json | format_toml.py --generate output.toml")
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
        with open(toml_path, "w", encoding="utf-8", newline="\n") as f:
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

    if "--hotstrings" in sys.argv:
        hotstrings_mode()
    elif "--generate" in sys.argv:
        generate_mode()
    else:
        format_mode()


if __name__ == "__main__":
    main()
