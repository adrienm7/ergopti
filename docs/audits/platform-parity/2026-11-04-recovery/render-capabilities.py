"""Render the revision-pinned audit capability snapshot, not a live certification."""

import json
from pathlib import Path
import sys
import subprocess

DIRECTORY = Path(__file__).resolve().parent


def render(data):
    lines = [
        "# Migration, update and restart capability comparison",
        "",
        "Audited source: `"
        + data["audited_sha"]
        + "`. This is a bounded, revision-pinned behavioral register. The existing production inventory generator owns the live website/README declarations; this snapshot does not replace it or certify native execution.",
        "",
        "Edit the JSON snapshot only when authoring a new audit; render with `python render-capabilities.py` and check with `python validate.py`. Earlier published audits remain immutable. Explicit policy, mechanism, constraints, observed defects and unknown intent are kept separate.",
        "",
        "| Capability | Windows | macOS | Linux | Classification and rationale | Evidence |",
        "| --- | --- | --- | --- | --- | --- |",
    ]

    def cell(value):
        return value.replace("|", "\\|").replace("\n", " ")

    for row in data["capabilities"]:
        evidence = ", ".join(
            "[" + path.split("/")[0] + "](" + path + ")" for path in row["evidence_reports"]
        )
        values = [
            row["title"],
            *(row["behavior"][os] for os in ("windows", "macos", "linux")),
            row["classification"] + ": " + row["rationale"],
            evidence,
        ]
        lines.append("| " + " | ".join(cell(value) for value in values) + " |")
    raw = "\n".join(lines) + "\n"
    root = DIRECTORY.parents[3]
    result = subprocess.run(
        [
            "node",
            str(root / "node_modules/prettier/bin/prettier.cjs"),
            "--stdin-filepath",
            "capabilities.md",
        ],
        input=raw,
        text=True,
        capture_output=True,
        cwd=root,
        check=True,
    )
    return result.stdout


if __name__ == "__main__":
    output = render(json.loads((DIRECTORY / "capabilities.json").read_text()))
    destination = DIRECTORY / "capabilities.md"
    if "--check" in sys.argv:
        assert destination.read_text() == output, (
            "Audit capability table differs from its JSON owner"
        )
    else:
        destination.write_text(output)
