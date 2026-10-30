# tools/dev/field-ips-summary.py
"""Scrubbed summaries of the app's own macOS crash reports for a field report.

The macOS collector (tools/dev/collect-macos-field-report.sh) runs this over
~/Library/Logs/DiagnosticReports. For each report of an owned process
(ErgoptiPlus and its launcher roles, Hammerspoon, Ollama, Python, Karabiner)
modified since the run started, it prints what names the cause and nothing
else: the process name and role, its parent and responsible process, its
code signing identifier, team, flags and validation category, the report
kind, the exception type, signal and
subtype, the termination namespace, code and indicator, and the top frames
of the faulting thread that belong to the app's own images. Paths, user
names, environment, register values and other images' frames are never
printed; any value outside a closed character set reads "redacted".

Usage: field-ips-summary.py --since <epoch seconds> <reports folder>
"""

import json
import os
import re
import sys

# The application name and bundle come from the one identifier declaration.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IDENTIFIERS = os.path.join(REPO_ROOT, "static/ergopti_plus/_shared/data/identifiers.json")
with open(IDENTIFIERS, encoding="utf-8") as identifiers_file:
    APP = json.load(identifiers_file)["app"]

OWNED_PROCESSES = re.compile(
    r"^(" + re.escape(APP["name"]) + r"|hammerspoon|ollama|python|karabiner)", re.IGNORECASE
)
# The images whose frames are the app's own code.
OWNED_IMAGES = re.compile(r"^(" + re.escape(APP["name"]) + r"|Hammerspoon|LuaSkin|lua)$")
OWNED_IMAGE_PATH = "/" + APP["bundle"] + "/"
SAFE_VALUE = re.compile(r"^[A-Za-z0-9 _.:+\-()\[\]<>,=#$]{1,160}$")
MAX_FRAMES = 12


def safe(value):
    """A value printed only when it carries no path or user text."""
    text = str(value)
    if text == "":
        return "none"
    if "/" in text or "@" in text or not SAFE_VALUE.match(text):
        return "redacted"
    return text


def parse_report(text):
    """The header and body objects of an .ips report, or None for another format."""
    first, _, rest = text.partition("\n")
    try:
        header = json.loads(first)
        body = json.loads(rest) if rest.strip() else {}
    except ValueError:
        return None
    if not isinstance(header, dict) or not isinstance(body, dict):
        return None
    return header, body


def owned_image_indexes(body):
    """Indexes of usedImages that are the app's own."""
    indexes = set()
    for index, image in enumerate(body.get("usedImages") or []):
        if not isinstance(image, dict):
            continue
        name = str(image.get("name") or "")
        if OWNED_IMAGES.match(name) or OWNED_IMAGE_PATH in str(image.get("path") or ""):
            indexes.add(index)
    return indexes


def faulting_frames(body):
    """The faulting thread's frames in the app's own images, top first."""
    threads = body.get("threads") or []
    index = body.get("faultingThread")
    if not isinstance(index, int) or not 0 <= index < len(threads):
        return []
    images = body.get("usedImages") or []
    owned = owned_image_indexes(body)
    lines = []
    for position, frame in enumerate(threads[index].get("frames") or []):
        if not isinstance(frame, dict) or frame.get("imageIndex") not in owned:
            continue
        image = images[frame["imageIndex"]].get("name", "image")
        if frame.get("symbol"):
            where = f"{frame['symbol']}+{frame.get('symbolLocation', 0)}"
        else:
            where = f"0x{int(frame.get('imageOffset', 0)):x}"
        lines.append(f"#{position} {safe(image)} {safe(where)}")
        if len(lines) >= MAX_FRAMES:
            break
    return lines


def summary(name, text):
    """The printed lines of one report."""
    lines = [f"== {safe(name)}"]
    parsed = parse_report(text)
    if parsed is None:
        lines.append("  format: not_ips")
        return lines
    header, body = parsed
    lines.append(f"  process: {safe(body.get('procName') or header.get('app_name') or 'unknown')}")
    lines.append(f"  bug_type: {safe(header.get('bug_type', 'unknown'))}")
    # Who started the process and under which signing identity: a launch
    # constraint names the parent (launchd for a ServiceManagement agent), the
    # role and the code signature it judged.
    for key in (
        "procRole",
        "parentProc",
        "responsibleProc",
        "codeSigningID",
        "codeSigningTeamID",
        "codeSigningFlags",
        "codeSigningValidationCategory",
        "codeSigningTrustLevel",
    ):
        if key in body:
            lines.append(f"  {key}: {safe(body[key])}")
    exception = body.get("exception") or {}
    for key in ("type", "signal", "subtype", "codes"):
        if key in exception:
            lines.append(f"  exception.{key}: {safe(exception[key])}")
    termination = body.get("termination") or {}
    for key in ("namespace", "code", "indicator", "flags"):
        if key in termination:
            lines.append(f"  termination.{key}: {safe(termination[key])}")
    frames = faulting_frames(body)
    lines.append(f"  owned_frames: {len(frames)}")
    lines.extend("  " + frame for frame in frames)
    return lines


def main(argv):
    if len(argv) != 4 or argv[1] != "--since" or not argv[2].isdigit():
        print(
            "usage: field-ips-summary.py --since <epoch seconds> <reports folder>", file=sys.stderr
        )
        return 2
    since, folder = int(argv[2]), argv[3]
    if not os.path.isdir(folder):
        print("no reports folder")
        return 0
    names = []
    for name in sorted(os.listdir(folder)):
        path = os.path.join(folder, name)
        if OWNED_PROCESSES.match(name) and os.path.isfile(path) and os.path.getmtime(path) >= since:
            names.append(name)
    print(f"owned reports since the run started: {len(names)}")
    for name in names:
        with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as handle:
            print("\n".join(summary(name, handle.read())))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
