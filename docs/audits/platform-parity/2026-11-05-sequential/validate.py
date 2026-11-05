"""Validate pinned sequential audit artifacts, not native runtime correctness."""

from datetime import datetime
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
DIRECTORY = Path(__file__).resolve().parent
ROOT = DIRECTORY.parents[3]
AUDITED_SHA = "7aecd9a25b35efdcff68898919506dc2f6fd02d0"
CREATED_AT = "2026-11-05"
MODULES = ("wpm", "wrap-symbols", "personal-info")
ROLES = ("windows", "macos", "linux", "shared")


def require(condition, message):
    """Fail closed even when Python is invoked with optimization."""
    if not condition:
        raise ValueError(message)


def nonempty(value):
    """Return whether a field contains meaningful prose."""
    return isinstance(value, str) and bool(value.strip())


def artifact(owner, relative):
    """Confine an existing artifact lexically and through symlinks to its owner."""
    require(nonempty(relative) and "\\" not in relative and ":" not in relative, "artifact path")
    path = Path(relative)
    require(
        not path.is_absolute() and ".." not in path.parts and path.as_posix() == relative,
        "noncanonical artifact path",
    )
    result = owner / path
    require(
        result.resolve().is_relative_to(owner.resolve()) and result.is_file(),
        f"missing or escaped artifact: {relative}",
    )
    return result


def load(path):
    """Load LF-only UTF-8 JSON without universal-newline normalization."""
    raw = path.read_bytes()
    require(b"\r" not in raw, f"CR byte: {path}")
    return json.loads(raw.decode("utf-8"))


def identity(data, label, dated=True):
    """Enforce the campaign's exact source identity."""
    require(data.get("audited_sha") == AUDITED_SHA, f"{label}: SHA")
    if dated:
        require(data.get("created_at") == CREATED_AT, f"{label}: date")


def timestamp(value):
    """Parse an explicit, timezone-aware phase timestamp."""
    require(nonempty(value), "missing phase timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.utcoffset() is not None, "phase timestamp needs timezone")
    return parsed


def phases(data):
    """Require closure before advancing to each subsequent module."""
    identity(data, "phases", dated=False)
    entries = data.get("phases")
    require(
        isinstance(entries, list) and [x.get("module") for x in entries] == list(MODULES),
        "phase module order",
    )
    previous_close = None
    for entry in entries:
        require(entry.get("state") == "bounded_review_closed", "phase not closed")
        close = timestamp(entry.get("closed_utc"))
        start = entry.get("started_utc")
        if previous_close is not None:
            require(timestamp(start) >= previous_close, "phase sequence inversion")
        if start is not None:
            require(timestamp(start) <= close, "phase closes before start")
        previous_close = close
    return entries


def renderer():
    """Load the adjacent renderer without writing bytecode artifacts."""
    spec = importlib.util.spec_from_file_location(
        "sequential_capabilities", DIRECTORY / "render.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate(directory=DIRECTORY, repo_root=ROOT, check_source=True):
    """Validate canonical manifests, evidence, TODO, sequencing and generated table."""
    directory, repo_root = Path(directory), Path(repo_root)
    index = load(artifact(directory, "index.json"))
    identity(index, "index")
    require(index.get("schema_version") == 1, "index schema")
    require(index.get("module_order") == list(MODULES), "index module order")
    source = load(artifact(directory, "source.json"))
    identity(source, "source")
    require(source.get("module_order") == list(MODULES), "source module order")
    if check_source:
        subprocess.run(
            ["git", "cat-file", "-e", AUDITED_SHA + "^{commit}"], cwd=repo_root, check=True
        )
    phase_entries = phases(load(artifact(directory, "phases.json")))
    modules = index.get("modules")
    require(
        isinstance(modules, list) and [x.get("module") for x in modules] == list(MODULES),
        "index modules",
    )
    todo = artifact(repo_root, "TODO.md").read_text(encoding="utf-8")
    ids = set()
    for module in modules:
        name = module["module"]
        scopes = module.get("scopes")
        require(isinstance(scopes, list) and len(scopes) == len(ROLES), "scope cardinality")
        require({x.get("role") for x in scopes} == set(ROLES), "scope roles")
        module_ids = set()
        for scope in scopes:
            role = scope["role"]
            owner = directory / name / role
            require(owner.resolve().is_relative_to(directory.resolve()), "escaped scope directory")
            artifact(owner, "report.md")
            artifact(owner, "findings.json")
            canonical = owner.relative_to(repo_root).as_posix()
            require(scope.get("report") == canonical + "/report.md", "canonical report path")
            require(
                scope.get("manifest") == canonical + "/findings.json", "canonical manifest path"
            )
            report = artifact(repo_root, scope["report"])
            require(AUDITED_SHA in report.read_text(encoding="utf-8"), "report source SHA")
            manifest = load(artifact(repo_root, scope["manifest"]))
            identity(manifest, "manifest")
            require(manifest.get("schema_version") == 1, "manifest schema")
            require(manifest.get("scope") == name + "-" + role, "manifest scope")
            require(manifest.get("report_path") == scope["report"], "manifest report path")
            findings = manifest.get("findings")
            require(isinstance(findings, list), "findings list")
            scoped_ids = []
            for finding in findings:
                fid = finding.get("id")
                require(
                    isinstance(fid, str) and re.fullmatch(r"[A-Z][A-Z0-9]*-[0-9]{3}", fid),
                    "finding identity",
                )
                require(fid not in ids, "duplicate finding ID")
                ids.add(fid)
                module_ids.add(fid)
                scoped_ids.append(fid)
                require(
                    re.search(r"(?<![A-Z0-9-])" + re.escape(fid) + r"(?![A-Z0-9-])", todo),
                    f"missing TODO ID: {fid}",
                )
                for key in (
                    "title",
                    "reproduction",
                    "root_cause",
                    "silent_failure",
                    "regression_test",
                ):
                    require(nonempty(finding.get(key)), f"{fid}: {key}")
                require(
                    finding.get("severity") in {"critical", "high", "medium", "low"},
                    f"{fid}: severity",
                )
                require(
                    finding.get("confidence") in {"high", "medium", "low"}, f"{fid}: confidence"
                )
                guarantees = finding.get("guarantees")
                require(
                    isinstance(guarantees, list) and all(isinstance(x, str) for x in guarantees),
                    "guarantee tags",
                )
                require(
                    len(guarantees) == len(set(guarantees))
                    and set(guarantees) <= {"G1", "G2", "G3", "G4", "G5"},
                    "invalid guarantee tag",
                )
                additional = finding.get("additional_properties", [])
                require(
                    isinstance(additional, list)
                    and all(nonempty(x) and not re.fullmatch(r"G[0-9]+", x) for x in additional),
                    "named additional properties",
                )
                require(len(additional) == len(set(additional)), "duplicate additional property")
                require(guarantees or additional, "missing guarantee or named property")
                basis = finding.get("basis")
                require(
                    nonempty(basis)
                    or isinstance(basis, dict)
                    and bool(basis)
                    and all(nonempty(k) for k in basis)
                    and any(nonempty(v) for v in basis.values()),
                    "finding basis",
                )
                require(finding.get("source_report") == scope["report"], "finding source report")
                evidence = finding.get("evidence")
                require(
                    isinstance(evidence, list) and evidence and all(nonempty(x) for x in evidence),
                    "finding evidence",
                )
                require(len(evidence) == len(set(evidence)), "duplicate evidence")
                for relative in evidence:
                    evidence_path = artifact(owner, relative)
                    require(b"\r" not in evidence_path.read_bytes(), "CR byte in evidence")
            require(scope.get("ids") == scoped_ids, "index canonical IDs differ")
        phase = next(x for x in phase_entries if x["module"] == name)
        if "canonical_ids" in phase:
            require(
                isinstance(phase["canonical_ids"], list)
                and len(phase["canonical_ids"]) == len(set(phase["canonical_ids"]))
                and set(phase["canonical_ids"]) == module_ids,
                "phase canonical IDs differ",
            )
    shared = index.get("shared_mechanisms")
    require(isinstance(shared, dict), "shared mechanisms")
    for key, group in shared.items():
        require(
            nonempty(key) and isinstance(group, list) and group and all(nonempty(x) for x in group),
            "shared mechanism group",
        )
        require(len(group) == len(set(group)) and set(group) <= ids, "shared mechanism IDs")
    capabilities = load(artifact(directory, "capabilities.json"))
    renderer().check(capabilities, artifact(directory, "capabilities.md"), repo_root)
    for module in capabilities["modules"]:
        for row in module["capabilities"]:
            finding_ids = row.get("finding_ids", [])
            require(
                isinstance(finding_ids, list) and all(nonempty(x) for x in finding_ids),
                "capability finding IDs",
            )
            require(
                len(finding_ids) == len(set(finding_ids)) and set(finding_ids) <= ids,
                "capability finding ID provenance",
            )
            for relative in row.get("evidence", []):
                artifact(directory, relative)
    for path in directory.rglob("*"):
        if path.is_file() and path.suffix in {
            ".md",
            ".json",
            ".py",
            ".lua",
            ".mjs",
            ".js",
            ".log",
            ".ahk",
            ".txt",
            ".sh",
        }:
            require(b"\r" not in path.read_bytes(), f"CR byte: {path}")
    return len(ids)


def main():
    """Run final artifact validation against the canonical campaign directory."""
    count = validate()
    print(
        f"PASS: 12 bounded scopes, {count} unique canonical IDs; source, TODO, evidence, phase order, LF and rendered table"
    )
    print("Artifact validation only; no native runtime or exhaustive-coverage certification.")


if __name__ == "__main__":
    main()
