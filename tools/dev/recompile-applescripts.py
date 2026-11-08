# tools/dev/recompile-applescripts.py
"""Recompiles every tracked compiled AppleScript whose source has changed.

A compiled script (.scpt) is the product of the .applescript beside it, but
only a Mac can compile it (osacompile), so an edit to the source on another
OS leaves the shipped .scpt stale. The macOS field report collector
(tools/dev/collect-macos-field-report.sh) runs this on the maintainer's Mac.

For each tracked .applescript with a tracked .scpt of the same name in the
same folder, the source is compiled into a temporary file, and both that file
and the tracked .scpt are decompiled (osadecompile); when the two texts
differ, the temporary file replaces the .scpt. Both sides pass through the
same decompiler, so its own spelling (line continuations, keywords, escapes,
indentation) never reads as a change. Comparing the decompiled .scpt with the
source text instead failed on every script the decompiler respells
(Encryptor, field report 2026-11-08: roundtrip_mismatch). The comparison
still ignores line endings, the indentation and the blank lines.

Prints one line per script (up_to_date, recompiled), then
`scpt_recompiled:<n>`. A script that cannot be judged or rebuilt prints
`scpt_failed:<path>:<reason>`, keeps its .scpt untouched, and the exit status
is 1 once every script was tried.

Usage: recompile-applescripts.py <repository root>
"""

import os
import subprocess
import sys
import tempfile

SOURCE_SUFFIX = ".applescript"
COMPILED_SUFFIX = ".scpt"
# Seconds one osacompile or osadecompile may take.
TOOL_TIMEOUT_SECONDS = 60


def normalized(text):
    """The script text without what osadecompile reformats."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return [line.strip() for line in lines if line.strip() != ""]


def tracked_pairs(root):
    """The (source, compiled) relative paths git tracks side by side."""
    listing = subprocess.run(
        ["git", "-C", root, "ls-files", "-z", "*" + SOURCE_SUFFIX, "*" + COMPILED_SUFFIX],
        check=True,
        capture_output=True,
    ).stdout.decode("utf-8")
    files = {name for name in listing.split("\0") if name}
    pairs = []
    for name in sorted(files):
        if name.endswith(SOURCE_SUFFIX):
            compiled = name[: -len(SOURCE_SUFFIX)] + COMPILED_SUFFIX
            if compiled in files:
                pairs.append((name, compiled))
    return pairs


def decompile(path):
    """The text osadecompile prints for one compiled script, or None."""
    try:
        result = subprocess.run(
            ["osadecompile", path], capture_output=True, timeout=TOOL_TIMEOUT_SECONDS
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", errors="replace")


def rebuild(root, source, compiled):
    """Judges one pair and rebuilds it when stale; returns (state, reason)."""
    source_path = os.path.join(root, source)
    compiled_path = os.path.join(root, compiled)
    current = decompile(compiled_path)
    if current is None:
        return "failed", "decompile_existing"
    descriptor, candidate = tempfile.mkstemp(
        suffix=COMPILED_SUFFIX, dir=os.path.dirname(compiled_path)
    )
    os.close(descriptor)
    try:
        try:
            result = subprocess.run(
                ["osacompile", "-o", candidate, source_path],
                capture_output=True,
                timeout=TOOL_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired):
            return "failed", "osacompile_unavailable"
        if result.returncode != 0:
            return "failed", "osacompile_exit_" + str(result.returncode)
        rebuilt = decompile(candidate)
        if rebuilt is None:
            return "failed", "decompile_rebuilt"
        if normalized(rebuilt) == normalized(current):
            return "up_to_date", None
        os.replace(candidate, compiled_path)
        return "recompiled", None
    finally:
        if os.path.exists(candidate):
            os.remove(candidate)


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: recompile-applescripts.py <repository root>", file=sys.stderr)
        return 2
    root = argv[1]
    recompiled = 0
    failed = False
    for source, compiled in tracked_pairs(root):
        state, reason = rebuild(root, source, compiled)
        if state == "failed":
            failed = True
            print("scpt_failed:" + compiled + ":" + reason)
            continue
        if state == "recompiled":
            recompiled += 1
        print(state + " " + compiled)
    print("scpt_recompiled:" + str(recompiled))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
