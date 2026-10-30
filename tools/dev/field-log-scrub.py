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

Each driver spells these lines its own way: macOS logs the expansion with both
sides, Windows logs the fired trigger alone and Windows and Linux log typed
characters, selections and model text in their error and diagnostic lines. The
continuation lines of a withheld body go with it, a multi-line body has no
timestamp of its own. tools/test/test-field-log-scrub.cjs renders every Windows
and Linux template from the source, so a new spelling cannot pass unnoticed.
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
# Windows names the fired trigger alone, the replacement is never on the line.
FIRED_TRIGGER = re.compile(
    r"(?P<head>KL_LogHotstring: trigger=|Fire-log drain failed for trigger )"
    r"'(?P<trigger>.*?)'(?P<tail>(?: cat=|: ).*)$"
)
# One line each: the text between the head and the tail leaves the report.
WITHHELD = tuple(
    re.compile(pattern)
    for pattern in (
        # Windows: the typed character, the first tooltip row, the model's text.
        r"(?P<head>\b(?:KEEP|DISMISS): keystroke )'.*'(?P<tail> (?:ignored|typed) .*)$",
        r"(?P<head>\b(?:OnChar error|UIA wrap error) for char )'.*'(?P<tail>: .*)$",
        r"(?P<head>DBG calling TooltipShow: \d+ item\(s\), first=)'.*'(?P<tail>\.)$",
        r"(?P<head>Raw \(\d+c\): ).*(?P<tail>)$",
        # The selection the shortcut acted on: a path, a URL or any selected text.
        r"(?P<head>\b(?:Opening|Handed) the selected \w+ )'.*'(?P<tail>(?:…| to the shell\.).*)$",
        r"(?P<head>Registry navigation to )'.*'(?P<tail> did not .*)$",
        # Linux: the replacement refused by the injector, the typed symbol.
        r"(?P<head>\bCannot deliver )'.*'(?P<tail> (?:before|—) .*)$",
        r"(?P<head>selection window opened — typing )'.*'(?P<tail>\.)$",
        # Every driver: model and payload text is quoted in guillemets, and no
        # other log line uses them. To the end of the line: an unterminated quote
        # is a body that continues on the next ones.
        r"(?P<head>[^«]*)«.*(?P<tail>)$",
    )
)
# The start of a record: a line without it continues the record before it.
RECORD_START = re.compile(r"^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}|=====)")


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


def scrub_record(line, outputs):
    """Returns one log line without the user's typed text.

    Args:
        line: One log line, without its line ending.
        outputs: The bundled_outputs map.

    Returns:
        A pair: the line, rewritten when it carries typed text, and whether it
        was a line whose body is withheld.
    """
    match = EXPANSION.search(line)
    if match:
        trigger, repl = match.group("trigger"), match.group("repl")
        known = outputs.get(trigger.lower())
        shown = f"'{trigger}'" if known is not None else "<personal trigger>"
        source = "<bundled>" if known is not None and repl.lower() in known else "<personal>"
        return line[: match.start()] + f"{match.group('head')}{shown} → {source}.", True
    match = FIRED_TRIGGER.search(line)
    if match:
        trigger = match.group("trigger")
        shown = f"'{trigger}'" if trigger.lower() in outputs else "<personal trigger>"
        return line[: match.start()] + match.group("head") + shown + match.group("tail"), True
    for pattern in (PROMPT, CHUNK):
        match = pattern.search(line)
        if match:
            return line[: match.start()] + match.group("head") + "<text withheld>", True
    for pattern in WITHHELD:
        match = pattern.search(line)
        if match:
            return (
                line[: match.start()]
                + match.group("head")
                + "<text withheld>"
                + match.group("tail"),
                True,
            )
    return line, False


def scrub(lines, outputs):
    """Yields the lines of a log without the user's typed text.

    Args:
        lines: The log's lines, without their line endings.
        outputs: The bundled_outputs map.

    Yields:
        The lines to keep, rewritten when they carry typed text.
    """
    dropping = False
    for line in lines:
        if dropping and not RECORD_START.match(line):
            continue
        kept, dropping = scrub_record(line, outputs)
        yield kept


def main():
    """Copies the log scrubbed and returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=pathlib.Path, help="the log to copy")
    parser.add_argument("target", type=pathlib.Path, help="where the scrubbed copy goes")
    parser.add_argument("bundled", type=pathlib.Path, help="the bundled hotstrings folder")
    arguments = parser.parse_args()
    outputs = bundled_outputs(arguments.bundled)
    # utf-8-sig: the Windows logger starts a new file with a BOM. A report is stored
    # with LF on every OS, whatever the log was written with.
    with arguments.source.open(encoding="utf-8-sig", errors="replace") as source:
        with arguments.target.open("w", encoding="utf-8", newline="\n") as target:
            for line in scrub((raw.rstrip("\n") for raw in source), outputs):
                target.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
