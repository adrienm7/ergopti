"""Render the bounded sequential capability register from its JSON owner."""

import argparse
import json
from pathlib import Path
import subprocess

DIRECTORY = Path(__file__).resolve().parent
AUDITED_SHA = "7aecd9a25b35efdcff68898919506dc2f6fd02d0"
MODULES = ("wpm", "wrap-symbols", "personal-info")
CLASSIFICATIONS = {
    "raw_parity",
    "explicit_intent",
    "native_constraint",
    "unknown_intent",
    "observed_defect",
    "observed_limit",
    "native_alternative",
    "documentation_only",
}


def require(condition, message):
    """Reject malformed owner data even under Python optimization."""
    if not condition:
        raise ValueError(message)


def nonempty(value):
    """Return whether a value is meaningful prose."""
    return isinstance(value, str) and bool(value.strip())


def validate(data):
    """Check capability identities, bounded modules and explicit classifications."""
    require(data.get("schema_version") == 1, "capabilities schema")
    require(data.get("audited_sha") == AUDITED_SHA, "capabilities SHA")
    modules = data.get("modules")
    require(isinstance(modules, list), "capability modules list")
    require([item.get("module") for item in modules] == list(MODULES), "capability modules")
    seen = set()
    for module in modules:
        rows = module.get("capabilities")
        require(isinstance(rows, list) and rows, "bounded capability rows required")
        for row in rows:
            identity = row.get("id")
            require(nonempty(identity) and identity not in seen, "duplicate capability ID")
            seen.add(identity)
            require(row.get("classification") in CLASSIFICATIONS, "capability classification")
            for field in ("contract", "windows", "macos", "linux", "basis"):
                require(nonempty(row.get(field)), f"capability {identity}: {field}")
            evidence = row.get("evidence", [])
            require(
                isinstance(evidence, list) and all(nonempty(x) for x in evidence),
                "capability evidence",
            )
            require(len(evidence) == len(set(evidence)), "duplicate capability evidence")


def cell(value):
    """Escape Markdown cell separators and physical line breaks."""
    return value.replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def render(data, repo_root=None):
    """Build deterministic Markdown and format with the repository Prettier."""
    validate(data)
    root = Path(repo_root) if repo_root else DIRECTORY.parents[3]
    lines = [
        "# Sequential module capability comparison",
        "",
        f"Audited source: `{AUDITED_SHA}`. Date: 2026-11-05.",
        "",
        "Generated from `capabilities.json` by `python3 render.py`; verify with "
        "`python3 render.py --check`.",
        "",
        "This register describes bounded evidence. It does not certify exhaustive "
        "coverage or native desktop receiving.",
        "",
        "Classifications: `raw_parity` means matching bounded descriptions/contracts, "
        "without native receiving or current-runtime certification; `explicit_intent` "
        "records stated product policy; `native_constraint` records a mechanism's "
        "documented constraints; `native_alternative` records different routes to "
        "a related result; `unknown_intent` needs a product decision; `observed_defect` "
        "references a qualified finding; `observed_limit` records bounded or guarded "
        "behavior; `documentation_only` records stale descriptions.",
        "",
    ]
    for module in data["modules"]:
        lines.extend(
            [
                "## " + module["module"],
                "",
                "| ID | Contract | Windows | macOS | Linux | Classification | Basis | Evidence |",
                "| --- | --- | --- | --- | --- | --- | --- | --- |",
            ]
        )
        for row in module["capabilities"]:
            values = [
                row[key]
                for key in (
                    "id",
                    "contract",
                    "windows",
                    "macos",
                    "linux",
                    "classification",
                    "basis",
                )
            ]
            values.append(", ".join(f"[{path}]({path})" for path in row.get("evidence", [])))
            lines.append("| " + " | ".join(cell(value) for value in values) + " |")
        lines.append("")
    result = subprocess.run(
        [
            "node",
            str(root / "node_modules/prettier/bin/prettier.cjs"),
            "--stdin-filepath",
            "capabilities.md",
        ],
        input="\n".join(lines),
        text=True,
        capture_output=True,
        check=True,
        cwd=root,
    )
    return result.stdout


def check(data, destination, repo_root=None):
    """Reject a missing or stale generated table without changing it."""
    output = render(data, repo_root)
    require(
        destination.is_file() and destination.read_bytes() == output.encode("utf-8"),
        "capabilities.md drift",
    )


def main():
    """Write the generated table, or verify it without mutation."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    data = json.loads((DIRECTORY / "capabilities.json").read_text(encoding="utf-8"))
    destination = DIRECTORY / "capabilities.md"
    if options.check:
        check(data, destination)
        print("PASS capability table matches its JSON owner")
    else:
        destination.write_bytes(render(data).encode("utf-8"))


if __name__ == "__main__":
    main()
