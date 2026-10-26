#!/usr/bin/env python3
"""Read one required native build input from the shared closed pin contract."""

import json
from pathlib import Path
import re
import sys

FIELDS = {
    "lua54": {"version", "url", "sha256"},
    "luv": {"repository", "revision"},
    "lfs": {"repository", "revision"},
}


def unique_fields(pairs):
    """Reject duplicate fields instead of silently choosing a build input."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate native source pin field")
        result[key] = value
    return result


def read_pins():
    """Refuse incomplete, ambiguous or unknown build inputs before any download."""
    data = json.loads(
        Path(__file__).with_name("native-source-pins.json").read_text(encoding="utf-8"),
        object_pairs_hook=unique_fields,
    )
    if not isinstance(data, dict) or set(data) != set(FIELDS):
        raise ValueError("Native source pin sections refused")
    for name, fields in FIELDS.items():
        entry = data[name]
        if not isinstance(entry, dict) or set(entry) != fields:
            raise ValueError("Native source pin fields refused")
        if any(
            not isinstance(value, str) or not value or any(c in value for c in "\0\r\n")
            for value in entry.values()
        ):
            raise ValueError("Native source pin value refused")
        if name == "lua54":
            if not re.fullmatch(r"5\.4\.[0-9]+", entry["version"]) or not re.fullmatch(
                r"[0-9a-f]{64}", entry["sha256"]
            ):
                raise ValueError("Lua source identity refused")
            if entry["url"] != "https://www.lua.org/ftp/lua-" + entry["version"] + ".tar.gz":
                raise ValueError("Lua source URL refused")
        elif not re.fullmatch(
            r"https://github\.com/[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+\.git", entry["repository"]
        ) or not re.fullmatch(r"[0-9a-f]{40}", entry["revision"]):
            raise ValueError("Native Git source identity refused")
    return data


if __name__ == "__main__":
    try:
        if (
            len(sys.argv) != 3
            or sys.argv[1] not in FIELDS
            or sys.argv[2] not in FIELDS[sys.argv[1]]
        ):
            raise ValueError("Native source pin query refused")
        print(read_pins()[sys.argv[1]][sys.argv[2]])
    except (OSError, ValueError, TypeError) as failure:
        print(str(failure), file=sys.stderr)
        sys.exit(1)
