"""Validate adjudicated word-reset audit metadata and render bounded projections."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

AUDITED_SHA = "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e"
CREATED_AT = "2026-11-05"
ROLES = ("windows", "macos", "linux", "shared")
BASES = {"source", "actual-owner", "native"}
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
    """Reject invalid owners even under optimized Python execution."""
    if not condition:
        raise ValueError(message)


def prose(value):
    """Return whether a string carries nonempty prose."""
    return isinstance(value, str) and bool(value.strip())


def artifact(directory, relative):
    """Resolve a regular campaign artifact without traversal or symlink hops."""
    require(prose(relative) and "\\" not in relative and ":" not in relative, "artifact path")
    path = Path(relative)
    require(
        not path.is_absolute() and ".." not in path.parts and path.as_posix() == relative,
        "noncanonical artifact path",
    )
    current = Path(directory)
    require(not current.is_symlink(), "campaign root symlink")
    for part in path.parts:
        current = current / part
        require(not current.is_symlink(), f"symlink artifact: {relative}")
    require(current.is_file(), f"missing artifact: {relative}")
    require(current.resolve().is_relative_to(Path(directory).resolve()), "escaped artifact")
    return current


def evidence(directory, values):
    """Validate evidence references and any explicitly pinned byte hashes."""
    require(isinstance(values, list) and values, "nonempty evidence required")
    seen = set()
    for entry in values:
        require(isinstance(entry, dict) and set(entry) <= {"path", "sha256"}, "evidence object")
        relative = entry.get("path")
        path = artifact(directory, relative)
        require(relative not in seen, "duplicate evidence path")
        seen.add(relative)
        if "sha256" in entry:
            digest = entry["sha256"]
            require(
                isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), "evidence digest"
            )
            require(
                hashlib.sha256(path.read_bytes()).hexdigest() == digest, "evidence digest mismatch"
            )


def qualified(item):
    """Require explicit observation level and limitations for each coverage claim."""
    require(item.get("basis") in BASES, "observation basis")
    require(prose(item.get("qualification")), "observation qualification")


def validate(data, directory):
    """Validate one bounded, adjudicated owner without certifying runtime parity."""
    require(isinstance(data, dict), "owner object")
    require(type(data.get("schema_version")) is int and data["schema_version"] == 1, "schema")
    require(data.get("audited_sha") == AUDITED_SHA, "audited SHA")
    require(data.get("created_at") == CREATED_AT, "creation date")
    require(data.get("module") == "word-reset", "bounded module")
    roles = data.get("roles")
    require(isinstance(roles, dict) and set(roles) == set(ROLES), "four exact role slots")
    finding_ids = set()
    reports = set()
    for role in ROLES:
        entry = roles[role]
        require(isinstance(entry, dict), "role object")
        report = entry.get("report")
        text = artifact(directory, report).read_text(encoding="utf-8")
        require(AUDITED_SHA in text, f"report source SHA: {role}")
        require(report not in reports, "role report reused")
        reports.add(report)
        evidence(directory, entry.get("evidence"))
        rows = entry.get("coverage")
        require(isinstance(rows, list) and rows, "nonempty bounded coverage")
        aspects = set()
        for row in rows:
            require(isinstance(row, dict), "coverage object")
            aspect = row.get("aspect")
            require(prose(aspect) and aspect not in aspects, "coverage aspect")
            aspects.add(aspect)
            qualified(row)
            evidence(directory, row.get("evidence"))
        findings = entry.get("findings")
        require(isinstance(findings, list), "findings list")
        for finding in findings:
            require(isinstance(finding, dict), "finding object")
            identity = finding.get("id")
            require(
                prose(identity) and re.fullmatch(r"[A-Z][A-Z0-9]*-[0-9]{3}", identity), "finding ID"
            )
            require(identity not in finding_ids, "duplicate finding ID")
            finding_ids.add(identity)
            require(finding.get("severity") in {"critical", "high", "medium", "low"}, "severity")
            require(finding.get("confidence") in {"high", "medium", "low"}, "confidence")
            for field in (
                "title",
                "reproduction",
                "root_cause",
                "silent_failure",
                "regression_test",
            ):
                require(prose(finding.get(field)), f"finding {field}")
            guarantees = finding.get("guarantees")
            require(
                isinstance(guarantees, list) and all(isinstance(g, str) for g in guarantees),
                "guarantees list",
            )
            require(
                len(guarantees) == len(set(guarantees))
                and set(guarantees) <= {"G1", "G2", "G3", "G4", "G5"},
                "guarantees",
            )
            properties = finding.get("additional_properties", [])
            require(
                isinstance(properties, list) and all(prose(p) for p in properties),
                "additional properties",
            )
            require(guarantees or properties, "finding needs guarantee or named property")
            qualified(finding)
            evidence(directory, finding.get("evidence"))
    capabilities = data.get("capabilities")
    require(isinstance(capabilities, list) and capabilities, "bounded capabilities list")
    capability_ids = set()
    for row in capabilities:
        require(isinstance(row, dict), "capability object")
        identity = row.get("id")
        require(prose(identity) and identity not in capability_ids, "capability ID")
        capability_ids.add(identity)
        for field in ("contract", "windows", "macos", "linux", "basis"):
            require(prose(row.get(field)), f"capability {field}")
        require(row.get("classification") in CLASSIFICATIONS, "capability classification")
        statuses = row.get("availability")
        require(
            isinstance(statuses, dict) and set(statuses) == set(ROLES[:3]), "per-OS availability"
        )
        require(
            all(
                value in {"present", "absent", "partial", "native-alternative", "unverified"}
                for value in statuses.values()
            ),
            "availability status",
        )
        observations = row.get("observation_basis")
        require(
            isinstance(observations, dict) and set(observations) == set(ROLES[:3]),
            "per-OS observation basis",
        )
        require(all(value in BASES for value in observations.values()), "per-OS observation value")
        evidence(directory, row.get("evidence"))
        linked = row.get("finding_ids", [])
        require(
            isinstance(linked, list) and all(isinstance(x, str) for x in linked),
            "capability finding IDs",
        )
        require(
            len(linked) == len(set(linked)) and set(linked) <= finding_ids,
            "unknown finding reference",
        )
        if row["classification"] == "observed_defect":
            require(linked, "observed defect needs confirmed finding")


def json_bytes(data):
    """Serialize deterministic LF-only UTF-8 JSON."""
    return (json.dumps(data, indent="\t", ensure_ascii=False) + "\n").encode("utf-8")


def cell(value):
    """Escape Markdown table delimiters and physical line breaks."""
    return value.replace("\\", "\\\\").replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def projections(data, repo_root=None):
    """Generate canonical bounded indexes without mutating reviewer submissions."""
    identity = {key: data[key] for key in ("schema_version", "audited_sha", "created_at", "module")}
    findings = []
    roles = []
    for role in ROLES:
        owner = data["roles"][role]
        roles.append(
            {
                "role": role,
                "report": owner["report"],
                "evidence": owner["evidence"],
                "ids": [f["id"] for f in owner["findings"]],
                "coverage": owner["coverage"],
            }
        )
        findings.extend(
            dict(f, role=role, source_report=owner["report"]) for f in owner["findings"]
        )
    markdown = [
        "# Word-reset and AI-context capability comparison",
        "",
        f"Audited source: `{AUDITED_SHA}`. Date: {CREATED_AT}.",
        "",
        "Generated from adjudicated `owner.json` by `python3 project.py`. "
        "This bounded evidence register does not certify exhaustive coverage or native desktop receiving.",
        "",
        "| ID | Contract | Windows | macOS | Linux | Classification | Basis | Evidence |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in data["capabilities"]:
        fields = [row["id"], row["contract"]]
        fields.extend(
            f"{row['availability'][os]} ({row['observation_basis'][os]}): {row[os]}"
            for os in ROLES[:3]
        )
        fields.extend([row["classification"], row["basis"]])
        links = "; ".join(f"[{e['path']}]({e['path']})" for e in row["evidence"])
        markdown.append("| " + " | ".join(cell(x) for x in fields) + " | " + links + " |")
    result = {
        "index.json": json_bytes(dict(identity, roles=roles)),
        "findings.json": json_bytes(dict(identity, findings=findings)),
        "capabilities.json": json_bytes(dict(identity, capabilities=data["capabilities"])),
        "capabilities.md": ("\n".join(markdown) + "\n").encode("utf-8"),
    }
    if repo_root is not None:
        prettier = Path(repo_root).resolve() / "node_modules/prettier/bin/prettier.cjs"
        require(prettier.is_file(), "repository Prettier missing")
        result = {
            name: subprocess.run(
                ["node", str(prettier), "--stdin-filepath", name],
                cwd=repo_root,
                input=content,
                stdout=subprocess.PIPE,
                check=True,
            ).stdout
            for name, content in result.items()
        }
    return result


def main():
    """Validate owner metadata, then write or check its deterministic projections."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--repo-root", type=Path)
    args = parser.parse_args()
    owner = artifact(args.directory, "owner.json")
    raw = owner.read_bytes()
    require(b"\r" not in raw, "owner must use LF")
    data = json.loads(raw.decode("utf-8"))
    validate(data, args.directory)
    repo_root = args.repo_root
    if repo_root is None:
        repo_root = next(
            (
                parent
                for parent in args.directory.resolve().parents
                if (parent / "package.json").is_file()
            ),
            None,
        )
    for name, content in projections(data, repo_root).items():
        output = args.directory / name
        require(not output.is_symlink(), "generated output symlink")
        if args.check:
            require(
                output.is_file() and output.read_bytes() == content, f"stale projection: {name}"
            )
        else:
            output.write_bytes(content)
    print(
        "Word-reset audit metadata and four projections: valid (not runtime parity certification)."
    )


if __name__ == "__main__":
    main()
