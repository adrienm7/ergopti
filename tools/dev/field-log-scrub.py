#!/usr/bin/env python3
# tools/dev/field-log-scrub.py
"""Copy one ErgoptiPlus log with the user's typed text removed.

A field report is pushed to a public repository, and the DEBUG log the driver
writes by default carries what the user typed: every hotstring expansion as
"'trigger' → 'replacement'", up to 250 characters of each AI prompt, and each
streamed AI chunk. The copy keeps every other line as it is and rewrites those:

- an expansion keeps its trigger only when it is a bundled trigger (public,
  it is in this repository) and names its replacement <bundled> or <personal>,
  never its text, so the report still shows which entry fired;
- a prompt or a streamed chunk keeps its size and loses its text.
"""

import argparse
import pathlib
import re
import sys
import tomllib

EXPANSION = re.compile(
    r"(?P<head>(?:Auto|Terminator)-expand: )'(?P<trigger>.*?)' → '(?P<repl>.*?)'\.$"
)
PROMPT = re.compile(
    r"(?P<head>\bSTREAM_PROMPT \(\d+ chars\).*? -> |\bPROMPT \(\d+ chars\).*? -> ).*$"
)
CHUNK = re.compile(r"(?P<head>STREAM chunk \(\d+ bytes\): )'.*'$")


def bundled_outputs(folder):
    """Maps every bundled trigger, case-folded, to its replacements.

    Args:
        folder: The bundled hotstrings folder.

    Returns:
        A dict from folded trigger to the set of its folded outputs.
    """
    outputs = {}
    for path in sorted(folder.rglob("*.toml")):
        with path.open("rb") as handle:
            document = tomllib.load(handle)
        for section, tables in document.items():
            if section.startswith("_") or not isinstance(tables, list):
                continue
            for table in tables:
                for trigger, fields in table.items():
                    if isinstance(fields, dict) and isinstance(fields.get("output"), str):
                        outputs.setdefault(trigger.lower(), set()).add(fields["output"].lower())
    return outputs


def scrub(line, outputs):
    """Returns one log line without the user's typed text.

    Args:
        line: One log line, without its line ending.
        outputs: The bundled_outputs map.

    Returns:
        The line, rewritten when it carries typed text.
    """
    match = EXPANSION.search(line)
    if match:
        trigger, repl = match.group("trigger"), match.group("repl")
        known = outputs.get(trigger.lower())
        shown = f"'{trigger}'" if known is not None else "<personal trigger>"
        source = "<bundled>" if known is not None and repl.lower() in known else "<personal>"
        return line[: match.start()] + f"{match.group('head')}{shown} → {source}."
    for pattern, withheld in ((PROMPT, "<text withheld>"), (CHUNK, "<text withheld>")):
        match = pattern.search(line)
        if match:
            return line[: match.start()] + match.group("head") + withheld
    return line


def main():
    """Copies the log scrubbed and returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=pathlib.Path, help="the log to copy")
    parser.add_argument("target", type=pathlib.Path, help="where the scrubbed copy goes")
    parser.add_argument("bundled", type=pathlib.Path, help="the bundled hotstrings folder")
    arguments = parser.parse_args()
    outputs = bundled_outputs(arguments.bundled)
    with arguments.source.open(encoding="utf-8", errors="replace") as source:
        with arguments.target.open("w", encoding="utf-8") as target:
            for line in source:
                target.write(scrub(line.rstrip("\n"), outputs) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
