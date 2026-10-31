#!/usr/bin/env python3
# tools/dev/scrub-release-notes.py
"""Remove agent attribution lines from the bodies of published GitHub releases.

Releases published before 0ba0e90580 carry `Claude-Session:` trailers and
private session links that build_changelog.py now strips from new release
notes. This tool applies the same TOOL_ATTRIBUTION_RE to every existing
release body, so the published pages match what a new build would render.

It runs on the maintainer's machine: a cloud agent session may not edit
releases. It needs the GitHub CLI (`gh`) signed in with write access.

Usage:
    python3 tools/dev/scrub-release-notes.py            list what would change
    python3 tools/dev/scrub-release-notes.py --apply    edit those releases

Before editing, each original body is saved under build/release-notes-backup/
so a change can be undone by hand.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "build"))
from build_changelog import TOOL_ATTRIBUTION_RE

REPO = "adrienm7/ergopti"
BACKUP = ROOT / "build" / "release-notes-backup"


def scrub(body: str) -> str:
    """Return the body without attribution lines and the blank line before each."""
    kept: list[str] = []
    for line in body.split("\n"):
        if TOOL_ATTRIBUTION_RE.search(line):
            if kept and kept[-1].strip() == "":
                kept.pop()
            continue
        kept.append(line)
    return "\n".join(kept)


def gh(*args: str, payload: dict | None = None) -> str:
    """Run one `gh api` call and return its standard output."""
    command = ["gh", "api", *args]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(
        command,
        input=json.dumps(payload) if payload is not None else None,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"gh api {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def main() -> int:
    apply = "--apply" in sys.argv[1:]
    releases = json.loads(gh("--paginate", "--slurp", f"repos/{REPO}/releases"))
    releases = [release for page in releases for release in page]
    changed = 0
    for release in releases:
        body = release.get("body") or ""
        scrubbed = scrub(body)
        if scrubbed == body:
            continue
        changed += 1
        print(f"{release['tag_name']}: {len(body)} -> {len(scrubbed)} characters")
        if apply:
            BACKUP.mkdir(parents=True, exist_ok=True)
            (BACKUP / f"{release['tag_name']}.md").write_text(body, encoding="utf-8")
            gh(
                "--method",
                "PATCH",
                f"repos/{REPO}/releases/{release['id']}",
                payload={"body": scrubbed},
            )
    verb = "edited" if apply else "would be edited (run with --apply)"
    print(f"{changed} release(s) {verb}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
