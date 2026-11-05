"""Render the revision-pinned capability register without native certification."""

import argparse
import json
from pathlib import Path
import re
import subprocess


DIRECTORY = Path(__file__).resolve().parent
PLATFORMS = ("windows", "macos", "linux")
REPORTS = {
    f"{platform}-{scope}/report.md"
    for platform in PLATFORMS
    for scope in ("runtime", "webview", "diagnostics")
}
AUDITED_SHA = "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"


def validate(data):
    """Require the campaign identity, closed classifications and nine scopes."""
    assert data["schema_version"] == 1, "Unsupported capability schema"
    assert data["audited_sha"] == AUDITED_SHA, "Unexpected audited source"
    assert data["created_at"] == "2026-11-05", "Unexpected audit date"
    classifications = data["classifications"]
    assert len(classifications) == len(set(classifications))
    assert set(classifications) == set(data["classification_meanings"])
    assert set(data["scope_register"]) == set(PLATFORMS)
    seen, cited = set(), set()
    for row in data["capabilities"]:
        assert re.fullmatch(r"[a-z][a-z0-9-]*", row["id"])
        assert row["id"] not in seen, "Duplicate capability identity"
        seen.add(row["id"])
        assert row["classification"] in classifications
        assert set(row["behavior"]) == set(PLATFORMS)
        for value in [row["title"], row["rationale"], *row["behavior"].values()]:
            assert isinstance(value, str) and value.strip()
        assert row["evidence_reports"], "Missing report provenance"
        assert set(row["evidence_reports"]) <= REPORTS
        cited.update(row["evidence_reports"])
        assert all(re.fullmatch(r"[A-Z]{3}-\d{3}", finding) for finding in row["finding_ids"])
        assert not {"LVB-002", "MRT-005"} & set(row["finding_ids"]), (
            "Excluded candidate reintroduced as a confirmed finding"
        )
    assert cited == REPORTS, "All nine bounded reports must be represented"
    adjudications = {row["id"]: row for row in data["adjudications"]}
    assert len(adjudications) == len(data["adjudications"])
    assert adjudications["LVB-002"]["disposition"] == "demoted_not_confirmed"
    assert adjudications["MRT-005"]["disposition"] == "refuted_not_confirmed"
    assert adjudications["WVB-002"]["disposition"] == "confirmed_shared_cause"
    assert adjudications["MVB-002"]["disposition"] == "confirmed_macos_effect"
    for row in adjudications.values():
        assert row["summary"].strip()
        assert row["evidence_reports"]
        assert set(row["evidence_reports"]) <= REPORTS


def cell(value):
    """Keep generated Markdown table cells on one line."""
    return value.replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def evidence(paths):
    """Render links to reports in the integrated campaign directory."""
    return ", ".join(f"[{path.split('/')[0]}]({path})" for path in paths)


def render(data):
    """Build a deterministic comparison exclusively from the JSON owner."""
    validate(data)
    lines = [
        "# " + data["title"],
        "",
        f"Date: {data['created_at']}. Audited source: `{data['audited_sha']}`.",
        "",
        data["evidence_boundary"],
        "",
        "Generated from `capabilities.json` by `python3 render-capabilities.py`. "
        "Check without writing with `python3 render-capabilities.py --check`. "
        "The production feature inventory remains a separate owner.",
        "",
        "## Scope and evidence",
        "",
        "| OS | Bounded subjects |",
        "| --- | --- |",
    ]
    for platform in PLATFORMS:
        lines.append(f"| {platform} | {cell(data['scope_register'][platform])} |")
    lines.extend(
        [
            "",
            "## Classifications",
            "",
            "| Classification | Meaning |",
            "| --- | --- |",
        ]
    )
    for classification in data["classifications"]:
        lines.append(
            f"| {classification} | " + cell(data["classification_meanings"][classification]) + " |"
        )
    lines.extend(
        [
            "",
            "## Capability comparison",
            "",
            "| Capability | Windows | macOS | Linux | Classification and rationale | Evidence |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
    )
    for row in data["capabilities"]:
        findings = (
            " Confirmed: " + ", ".join(row["finding_ids"]) + "." if row["finding_ids"] else ""
        )
        values = [
            row["title"],
            *(row["behavior"][platform] for platform in PLATFORMS),
            row["classification"] + ": " + row["rationale"] + findings,
            evidence(row["evidence_reports"]),
        ]
        lines.append("| " + " | ".join(cell(value) for value in values) + " |")
    lines.extend(
        [
            "",
            "## Coordinator adjudications",
            "",
            "These dispositions distinguish shared causes and actual reachable effects "
            "from provisional claims in the individual reports.",
            "",
            "| ID | Disposition | Actual conclusion | Evidence |",
            "| --- | --- | --- | --- |",
        ]
    )
    for row in data["adjudications"]:
        values = [
            row["id"],
            row["disposition"],
            row["summary"],
            evidence(row["evidence_reports"]),
        ]
        lines.append("| " + " | ".join(cell(value) for value in values) + " |")
    root = DIRECTORY.parents[3]
    formatted = subprocess.run(
        [
            "node",
            str(root / "node_modules/prettier/bin/prettier.cjs"),
            "--stdin-filepath",
            "capabilities.md",
        ],
        input="\n".join(lines) + "\n",
        text=True,
        capture_output=True,
        cwd=root,
        check=True,
    )
    return formatted.stdout


def main():
    """Render or check the generated Markdown without modifying other files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()
    data = json.loads((DIRECTORY / "capabilities.json").read_text(encoding="utf-8"))
    output = render(data)
    destination = DIRECTORY / "capabilities.md"
    if options.check:
        if not destination.is_file() or destination.read_text(encoding="utf-8") != output:
            parser.error("capabilities.md differs from its JSON owner; render it first")
        print(f"Capability register is current: {len(data['capabilities'])} rows, 9 scopes")
    else:
        destination.write_text(output, encoding="utf-8")


if __name__ == "__main__":
    main()
