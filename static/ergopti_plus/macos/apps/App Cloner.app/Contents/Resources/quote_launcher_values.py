#!/usr/bin/env python3
# apps/App Cloner.app/Contents/Resources/quote_launcher_values.py

"""Emit validated shell or Python assignments for generated launchers."""

import re
import shlex
import sys


NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def emit_assignments(language, pairs):
    """Return safe assignment statements for alternating name/value pairs."""
    if language not in {"shell", "python"}:
        raise ValueError("language must be shell or python")
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
