"""Execute the actual launcher with owned native command spies, never an app."""

import json
from pathlib import Path
import re
import subprocess
import sys


CASES = [
    ("empty", ""),
    ("folder", "/fixture/project"),
    ("colon-file", "/fixture/report:2026.txt"),
    ("tilde-file", "~/Documents"),
    ("https", "https://example.invalid/path?q=1"),
    ("http", "http://example.invalid/"),
    ("teams-double", "msteams://l/chat/0"),
    ("teams-chat", "msteams:/l/chat/0"),
    ("teams-calendar", "msteams:/calendar"),
    ("opaque", "mailto:fixture@example.invalid"),
    ("custom", "A+B.C-1:opaque"),
    ("non-scheme", "1invalid:filename"),
]
FAMILIES = ["native", "electron", "vscode"]
PORTS = r"""
set -euo pipefail
OPEN_ARG="$1"
APP_FAMILY="$2"
OWNED_ROOT="$3"
UNIQUE_ID=fixture.identity
SOURCE_APP=fixture-application
SRC_EXE=fixture-executable
USER_DATA_DIR="$OWNED_ROOT/profile"
SHARED_EXT_DIR="$OWNED_ROOT/extensions"
fixture_arch() {
    [[ "$#" -ge 2 && "$2" == fixture-executable ]] || { echo 'Invalid native arch boundary arguments' >&2; return 1; }
    case "$1" in -arm64|-x86_64) ;; *) echo 'Invalid native architecture' >&2; return 1 ;; esac
    printf '%s\0' "$#" "$@" >> "$OWNED_ROOT/executions.bin"
}
fixture_open() {
    [[ "$#" == 3 && "$1" == -a && "$2" == fixture-application ]] || { echo 'Invalid native open boundary arguments' >&2; return 1; }
    printf '%s\0' "$#" "$@" >> "$OWNED_ROOT/opens.bin"
}
fixture_sleep() {
    [[ "$#" == 1 && "$1" == 1 ]] || { echo 'Invalid native sleep boundary arguments' >&2; return 1; }
    printf '%s\0' "$#" "$@" >> "$OWNED_ROOT/sleeps.bin"
}
"""


def records(path):
    if not path.exists():
        return []
    fields = path.read_bytes().decode("utf-8").split("\0")
    if fields.pop() != "":
        raise AssertionError("The owned native boundary trace is incomplete")
    result = []
    while fields:
        count = int(fields.pop(0))
        if count < 1 or len(fields) < count:
            raise AssertionError("The owned native boundary trace has invalid framing")
        result.append(fields[:count])
        del fields[:count]
    return result


def launcher_body(source):
    start = "<<'LAUNCHER_BODY'\n"
    end = "\nLAUNCHER_BODY\n"
    if source.count(start) != 1 or source.count(end) != 1:
        raise AssertionError("The actual launcher body must have one complete source owner")
    body = source.split(start)[1].split(end)[0]
    for native, port in [
        ("/usr/bin/arch", "fixture_arch"),
        ("/usr/bin/open", "fixture_open"),
        ("\tsleep 1\n", "\tfixture_sleep 1\n"),
    ]:
        if body.count(native) != 1:
            raise AssertionError(f"The actual native boundary changed: {native}")
        body = body.replace(native, port)
    return body


def actual_ui_validation(source_path):
    source = source_path.read_text(encoding="utf-8")
    handlers = []
    for name in ["format_ui", "toLower", "validateOpenArg"]:
        pattern = rf"(?ms)^on {name}\([^\n]*\n.*?^end {name}$"
        matches = re.findall(pattern, source)
        if len(matches) != 1:
            raise AssertionError(f"The actual UI handler must exist exactly once: {name}")
        handlers.append(matches[0])
    program = "\n".join(line for line in source.splitlines() if line.startswith("use "))
    program += (
        "\n"
        + "\n".join(handlers)
        + """
set chatResult to my validateOpenArg("msteams:/l/chat/0", "/Applications/Teams.app", {})
set calendarResult to my validateOpenArg("msteams:/calendar", "/Applications/Teams.app", {})
return "chat:" & chatResult & (ASCII character 30) & "calendar:" & calendarResult
"""
    )
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "AppleScript", "-e", program],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0 or result.stderr:
        raise AssertionError(f"The actual UI validator did not execute: {result.stderr}")
    fields = result.stdout.removesuffix("\n").split("\x1e")
    if (
        len(fields) != 2
        or not fields[0].startswith("chat:")
        or not fields[1].startswith("calendar:")
    ):
        raise AssertionError("The actual UI validator returned an invalid observation frame")
    return {
        "teams-chat": fields[0][len("chat:") :],
        "teams-calendar": fields[1][len("calendar:") :],
    }


def main():
    source_path, root_path, shell, shell_root = sys.argv[1:5]
    root = Path(root_path)
    body = launcher_body(Path(source_path).read_text(encoding="utf-8"))
    output = []
    for family in FAMILIES:
        for name, value in CASES:
            identity = family + "-" + name
            owned = root / identity
            owned.mkdir()
            owned_shell = shell_root.rstrip("/") + "/" + identity
            result = subprocess.run(
                [shell, "-c", PORTS + "\n" + body, "owned-url-probe", value, family, owned_shell],
                capture_output=True,
                text=True,
                timeout=5,
            )
            output.append(
                {
                    "family": family,
                    "name": name,
                    "input": value,
                    "owned_shell": owned_shell,
                    "status": result.returncode,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "executions": records(owned / "executions.bin"),
                    "opens": records(owned / "opens.bin"),
                    "sleeps": records(owned / "sleeps.bin"),
                }
            )
    ui = actual_ui_validation(Path(sys.argv[5])) if len(sys.argv) == 6 else None
    print(json.dumps({"cases": output, "ui_validation": ui, "app_activation": "NOT EXECUTED"}))


if __name__ == "__main__":
    main()
