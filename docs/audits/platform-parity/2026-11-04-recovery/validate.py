"""Validate bounded audit artifacts; never infer current native feature parity."""

import importlib.util
import json
from pathlib import Path
import re
import subprocess

DIRECTORY = Path(__file__).resolve().parent
ROOT = DIRECTORY.parents[3]


def load(path):
    return json.loads(path.read_text())


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def main():
    index = load(DIRECTORY / "index.json")
    sha = index["audited_sha"]
    assert index["schema_version"] == 1 and re.fullmatch(r"[0-9a-f]{40}", sha)
    subprocess.run(["git", "cat-file", "-e", sha + "^{commit}"], cwd=ROOT, check=True)
    expected = {
        os + "-" + module
        for os in ("windows", "macos", "linux")
        for module in ("migration", "updater")
    }
    assert len(index["scopes"]) == len(expected)
    assert {entry["scope"] for entry in index["scopes"]} == expected
    todo = (ROOT / "TODO.md").read_text()
    ids = set()
    for scope in index["scopes"]:
        directory = DIRECTORY / scope["scope"]
        canonical = directory.relative_to(ROOT).as_posix()
        assert scope["manifest"] == canonical + "/findings.json"
        assert scope["report"] == canonical + "/report.md"
        report = ROOT / scope["report"]
        assert report.is_file() and sha in report.read_text()
        manifest = load(ROOT / scope["manifest"])
        assert manifest["schema_version"] == 1 and manifest["audited_sha"] == sha
        assert manifest["created_at"] == index["created_at"] == "2026-11-04"
        assert manifest["scope"] == scope["scope"] and manifest["report_path"] == scope["report"]
        os_name, module = scope["scope"].split("-")
        prefix = {"windows": "W", "macos": "M", "linux": "L"}[os_name] + {
            "migration": "FM",
            "updater": "UR",
        }[module]
        scoped_ids = []
        for finding in manifest["findings"]:
            fid = finding["id"]
            assert re.fullmatch(prefix + r"-[0-9]{3}", fid) and fid not in ids
            ids.add(fid)
            scoped_ids.append(fid)
            assert fid in todo, (fid, "missing TODO")
            for key in ("title", "reproduction", "root_cause", "silent_failure", "regression_test"):
                assert nonempty(finding.get(key)), (fid, key)
            assert finding["severity"] in {"critical", "high", "medium", "low"}
            assert finding["confidence"] in {"high", "medium", "low"}
            guarantees = finding["guarantees"]
            assert isinstance(guarantees, list) and len(guarantees) == len(set(guarantees))
            assert set(guarantees) <= {"G1", "G2", "G3", "G4", "G5"}
            additional = finding.get("additional_properties", [])
            assert isinstance(additional, list) and all(nonempty(v) for v in additional), fid
            if "additional_property" in finding:
                assert nonempty(finding["additional_property"]), fid
            assert guarantees or nonempty(finding.get("additional_property")) or additional, fid
            basis = finding.get("basis")
            assert (
                nonempty(basis)
                or isinstance(basis, dict)
                and nonempty(basis.get("kind"))
                and nonempty(basis.get("native_limits"))
            ), fid
            assert finding["source_report"] == scope["report"]
        assert scoped_ids == scope["ids"]
    for group in index["shared_mechanisms"].values():
        assert group and len(group) == len(set(group)) and set(group) <= ids
    capabilities = load(DIRECTORY / "capabilities.json")
    assert capabilities["schema_version"] == 1 and capabilities["audited_sha"] == sha
    seen = set()
    for row in capabilities["capabilities"]:
        assert row["id"] not in seen
        seen.add(row["id"])
        assert row["classification"] in capabilities["classifications"]
        assert set(row["behavior"]) == {"windows", "macos", "linux"}
        assert all(nonempty(v) for v in row["behavior"].values()) and nonempty(row["rationale"])
        assert row["evidence_reports"] and all(
            (DIRECTORY / path).is_file() for path in row["evidence_reports"]
        )
    allowed_evidence = {scope + "/report.md" for scope in expected}
    assert all(
        set(row["evidence_reports"]) <= allowed_evidence for row in capabilities["capabilities"]
    )
    spec = importlib.util.spec_from_file_location(
        "audit_capabilities", DIRECTORY / "render-capabilities.py"
    )
    renderer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(renderer)
    assert (DIRECTORY / "capabilities.md").read_text() == renderer.render(capabilities)
    for path in DIRECTORY.rglob("*.ahk"):
        raw = path.read_bytes()
        assert raw.startswith(b"\xef\xbb\xbf") and b"\r" not in raw, path
    for path in [
        ROOT / "TODO.md",
        ROOT / "docs/platform-parity-audit.md",
        *DIRECTORY.rglob("*.md"),
    ]:
        text = re.sub(r"```[\s\S]*?```|`[^`\n]*`", "", path.read_text())
        for raw in re.findall(r"\]\(([^)\n]+)\)", text):
            target = raw.split("#")[0].strip("<>")
            if target and ":" not in target and not target.startswith("/"):
                assert (path.parent / target).exists(), (path, target)
    print(
        f"PASS metadata: {len(expected)} scopes, {len(ids)} unique OS-scoped IDs, {len(seen)} capability rows; source/TODO/shared groups/evidence/encoding/rendered table/links."
    )
    print(
        "Revision-pinned artifact validation only; no native, exhaustiveness or current-runtime certification."
    )


if __name__ == "__main__":
    main()
