#!/usr/bin/env python3
# tools/dev/hotstring-collisions.py
"""List the personal hotstrings whose trigger is also a bundled trigger.

A field report has to show why a personal hotstring loses to, or hides, a
bundled one, but it is pushed to a public repository: the personal file itself
must never travel with it. Only the collisions are printed, and only what is
already public plus the user's own flags: the trigger (a bundled trigger, so
it is in this repository), the flags and priority of both sides, and where the
bundled entry lives. No replacement text is ever printed, personal or bundled,
and a personal trigger without a bundled twin is not named at all.
"""

import argparse
import pathlib
import sys
import tomllib

# The entry fields that decide matching and precedence; never the output.
FLAGS = (
    "is_word",
    "auto_expand",
    "is_case_sensitive",
    "is_case_sensitive_strict",
    "final_result",
    "priority",
)


def entries(path):
    """Yields (section, trigger, fields) for every hotstring of one TOML file.

    Args:
        path: The hotstring TOML file.

    Yields:
        The section name, the trigger and its inline table.
    """
    with path.open("rb") as handle:
        document = tomllib.load(handle)
    for section, tables in document.items():
        if section.startswith("_") or not isinstance(tables, list):
            continue
        for table in tables:
            for trigger, fields in table.items():
                if isinstance(fields, dict):
                    yield section, trigger, fields


def flags(fields):
    """Formats the matching and precedence flags of one entry.

    Args:
        fields: The entry's inline table.

    Returns:
        The flags as "name=value" pairs, absent ones omitted.
    """
    return " ".join(f"{name}={fields[name]}" for name in FLAGS if name in fields)


def main():
    """Prints the collisions and returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("personal", type=pathlib.Path, help="personal_hotstrings.toml")
    parser.add_argument("bundled", type=pathlib.Path, help="the bundled hotstrings folder")
    arguments = parser.parse_args()
    if not arguments.personal.is_file():
        print(f"no personal hotstrings file at {arguments.personal.name}")
        return 0
    bundled = {}
    for path in sorted(arguments.bundled.rglob("*.toml")):
        for section, trigger, fields in entries(path):
            bundled.setdefault(trigger.lower(), []).append((path.stem, section, trigger, fields))
    collisions = 0
    for _, trigger, fields in entries(arguments.personal):
        for stem, bundled_section, bundled_trigger, bundled_fields in bundled.get(
            trigger.lower(), []
        ):
            collisions += 1
            print(f"{bundled_trigger!r} personal {flags(fields)}")
            print(f"    bundled {stem}.{bundled_section} {flags(bundled_fields)}")
    print(f"{collisions} personal trigger(s) shared with a bundled one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
