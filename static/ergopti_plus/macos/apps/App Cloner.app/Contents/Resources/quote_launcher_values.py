#!/usr/bin/env python3
# apps/App Cloner.app/Contents/Resources/quote_launcher_values.py

"""Emit validated literals for generated launchers and bundle metadata."""

import re
import shlex
import sys
from xml.sax.saxutils import escape


NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def emit_assignments(language, pairs):
    """Return safe assignments or one XML text-node literal."""
    if language == "xml":
        if len(pairs) != 1:
            raise ValueError("XML emission requires exactly one value")
        return escape(pairs[0], {'"': "&quot;", "'": "&apos;"})
    if language not in {"shell", "python"}:
        raise ValueError("language must be shell, python, or xml")
    if len(pairs) == 0 or len(pairs) % 2 != 0:
        raise ValueError("assignments require one or more name/value pairs")

    lines = []
    for index in range(0, len(pairs), 2):
        name = pairs[index]
        value = pairs[index + 1]
        if not NAME_RE.fullmatch(name):
            raise ValueError(f"invalid assignment name: {name!r}")
        if language == "shell":
            lines.append(f"{name}={shlex.quote(value)}")
        else:
            lines.append(f"{name} = {value!r}")
    return "\n".join(lines) + "\n"


def main(argv):
    """Write assignment statements and return a process exit code."""
    try:
        output = emit_assignments(argv[1], argv[2:])
    except (IndexError, ValueError) as exc:
        print(f"quote_launcher_values.py: {exc}", file=sys.stderr)
        return 2
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
