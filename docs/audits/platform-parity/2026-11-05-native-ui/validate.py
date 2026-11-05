"""Validate revision-pinned audit artifacts, not live native feature parity."""

import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote

sys.dont_write_bytecode = True

DIRECTORY = Path(__file__).resolve().parent
ROOT = DIRECTORY.parents[3]
AUDITED_SHA = "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"
CREATED_AT = "2026-11-05"
EXCLUDED_IDS = {"LVB-002", "MRT-005"}
EXPECTED_SCOPES = {
    os_name + "-" + module
    for os_name in ("windows", "macos", "linux")
    for module in ("runtime", "webview", "diagnostics")
}


def read_text(path):
    return path.read_text(encoding="utf-8")


def load(path):
    return json.loads(read_text(path))


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def within(path, owner):
    return path.resolve().is_relative_to(owner.resolve())


def artifact(owner, relative):
    """Resolve an existing artifact without permitting lexical or symlink escape."""
    assert nonempty(relative) and "\\" not in relative, (owner, relative)
    path = Path(relative)
    assert not path.is_absolute() and ":" not in relative and ".." not in path.parts, relative
    assert path.as_posix() == relative, relative
    resolved = owner / path
    assert within(resolved, owner) and resolved.is_file(), resolved
    return resolved


def validate_links(path):
    text = re.sub(r"```[\s\S]*?```|`[^`\n]*`", "", read_text(path))
    for raw in re.findall(r"\]\(([^)\n]+)\)", text):
        target = unquote(raw.split("#")[0].strip("<>"))
        if not target or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target):
            continue
        destination = path.parent / target
        assert within(destination, ROOT) and destination.exists(), (path, target)


def main():
    index = load(DIRECTORY / "index.json")
    assert index["schema_version"] == 1
    assert index["audited_sha"] == AUDITED_SHA and index["created_at"] == CREATED_AT
    subprocess.run(["git", "cat-file", "-e", AUDITED_SHA + "^{commit}"], cwd=ROOT, check=True)
    scopes = index["scopes"]
    assert isinstance(scopes, list) and len(scopes) == len(EXPECTED_SCOPES)
    assert {entry["scope"] for entry in scopes} == EXPECTED_SCOPES
    todo = read_text(ROOT / "TODO.md")
    ids = set()
    for scope in scopes:
        name = scope["scope"]
        directory = DIRECTORY / name
        canonical = directory.relative_to(ROOT).as_posix()
        assert scope["manifest"] == canonical + "/findings.json"
        assert scope["report"] == canonical + "/report.md"
        manifest_path = artifact(ROOT, scope["manifest"])
        report_path = artifact(ROOT, scope["report"])
        assert within(manifest_path, directory) and within(report_path, directory)
        assert AUDITED_SHA in read_text(report_path), (name, "report source SHA")
        manifest = load(manifest_path)
        assert manifest["schema_version"] == 1 and manifest["audited_sha"] == AUDITED_SHA
        assert manifest["created_at"] == CREATED_AT and manifest["scope"] == name
        assert manifest["report_path"] == scope["report"]
        os_name, module = name.split("-")
        prefix = {"windows": "W", "macos": "M", "linux": "L"}[os_name] + {
            "runtime": "RT",
            "webview": "VB",
            "diagnostics": "DG",
        }[module]
        findings = manifest["findings"]
        assert isinstance(findings, list)
        scoped_ids = []
        for finding in findings:
            fid = finding["id"]
            assert re.fullmatch(prefix + r"-[0-9]{3}", fid), fid
            assert fid not in ids and fid not in EXCLUDED_IDS, fid
            ids.add(fid)
            scoped_ids.append(fid)
            assert re.search(r"(?<![A-Z0-9-])" + re.escape(fid) + r"(?![A-Z0-9-])", todo), (
                fid,
                "missing TODO",
            )
            for key in ("title", "reproduction", "root_cause", "silent_failure", "regression_test"):
                assert nonempty(finding.get(key)), (fid, key)
            assert finding["severity"] in {"critical", "high", "medium", "low"}, fid
            assert finding["confidence"] in {"high", "medium", "low"}, fid
            guarantees = finding["guarantees"]
            assert isinstance(guarantees, list) and len(guarantees) == len(set(guarantees)), fid
            assert set(guarantees) <= {"G1", "G2", "G3", "G4", "G5"}, fid
            additional = finding.get("additional_properties", [])
            assert isinstance(additional, list) and all(nonempty(value) for value in additional), (
                fid
            )
            assert len(additional) == len(set(additional)), fid
            if "additional_property" in finding:
                assert nonempty(finding["additional_property"]), fid
            assert guarantees or additional or nonempty(finding.get("additional_property")), fid
            basis = finding.get("basis")
            assert nonempty(basis) or (
                isinstance(basis, dict)
                and nonempty(basis.get("kind"))
                and nonempty(basis.get("native_limits"))
            ), fid
            assert finding["source_report"] == scope["report"], fid
            evidence = finding["evidence"]
            assert (
                isinstance(evidence, list)
                and evidence
                and all(nonempty(value) for value in evidence)
            ), fid
            assert len(evidence) == len(set(evidence)), fid
            for relative in evidence:
                artifact(directory, relative)
        # The coordinator's canonical list is authoritative; scratch discoveries
        # and numeric sequence gaps never supply an implicit expected count.
        assert isinstance(scope["ids"], list) and scoped_ids == scope["ids"], name
    assert not ids & EXCLUDED_IDS
    shared = index["shared_mechanisms"]
    assert isinstance(shared, dict)
    for group in shared.values():
        assert (
            isinstance(group, list)
            and group
            and len(group) == len(set(group))
            and set(group) <= ids
        )

    capabilities = load(DIRECTORY / "capabilities.json")
    assert capabilities["schema_version"] == 1 and capabilities["audited_sha"] == AUDITED_SHA
    classifications = capabilities["classifications"]
    assert (
        isinstance(classifications, list)
        and classifications
        and all(nonempty(value) for value in classifications)
    )
    assert len(classifications) == len(set(classifications))
    rows = capabilities["capabilities"]
    assert isinstance(rows, list) and rows
    allowed_reports = {name + "/report.md" for name in EXPECTED_SCOPES}
    seen = set()
    for row in rows:
        assert nonempty(row["id"]) and row["id"] not in seen
        seen.add(row["id"])
        assert row["classification"] in classifications
        assert set(row["behavior"]) == {"windows", "macos", "linux"}
        assert all(nonempty(value) for value in row["behavior"].values()) and nonempty(
            row["rationale"]
        )
        reports = row["evidence_reports"]
        assert isinstance(reports, list) and reports and len(reports) == len(set(reports))
        assert set(reports) <= allowed_reports
        for relative in reports:
            artifact(DIRECTORY, relative)
    renderer_path = artifact(DIRECTORY, "render-capabilities.py")
    spec = importlib.util.spec_from_file_location("audit_capabilities", renderer_path)
    renderer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renderer)
    assert read_text(artifact(DIRECTORY, "capabilities.md")) == renderer.render(capabilities)
    for path in DIRECTORY.rglob("*.ahk"):
        raw = path.read_bytes()
        assert raw.startswith(b"\xef\xbb\xbf") and b"\r" not in raw, path
    for path in [
        ROOT / "TODO.md",
        ROOT / "docs/platform-parity-audit.md",
        *DIRECTORY.rglob("*.md"),
    ]:
        validate_links(path)
    print(
        f"PASS metadata: {len(EXPECTED_SCOPES)} scopes, {len(ids)} canonical unique IDs, {len(seen)} capability rows; "
        "source/TODO/dispositions/evidence confinement/encoding/rendered table/links."
    )
    print(
        "Revision-pinned artifact validation only; no native, exhaustiveness or current-runtime certification."
    )


if __name__ == "__main__":
    main()
