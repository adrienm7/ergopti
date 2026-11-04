"""Validate this immutable campaign's metadata and references, not runtime parity."""

import json
from pathlib import Path
import re
import subprocess

DIRECTORY = Path(__file__).resolve().parent
ROOT = DIRECTORY.parents[3]


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def text(value):
    return isinstance(value, str) and bool(value.strip())


def main():
    index = load(DIRECTORY / "index.json")
    assert index["schema_version"] == 1
    sha = index["audited_sha"]
    assert re.fullmatch(r"[0-9a-f]{40}", sha)
    subprocess.run(["git", "cat-file", "-e", sha + "^{commit}"], cwd=ROOT, check=True)
    assert index["created_at"] == "2026-11-04"
    expected = {
        os + "-" + module
        for os in ("windows", "macos", "linux")
        for module in ("clipboard", "crypto", "config", "desktop")
    }
    assert {scope["scope"] for scope in index["scopes"]} == expected
    assert len(index["scopes"]) == len(expected)
    all_ids = set()
    todo = (ROOT / "TODO.md").read_text()
    for scope in index["scopes"]:
        os_name, module = scope["scope"].split("-")
        prefix = {"windows": "W", "macos": "M", "linux": "L"}[os_name] + {
            "clipboard": "CP",
            "crypto": "CR",
            "config": "CF",
            "desktop": "DS",
        }[module]
        canonical = (DIRECTORY / scope["scope"]).relative_to(ROOT).as_posix()
        assert scope["report"] == canonical + "/report.md"
        assert scope["manifest"] == canonical + "/findings.json"
        report = ROOT / scope["report"]
        manifest = load(ROOT / scope["manifest"])
        assert report.is_file()
        assert manifest["schema_version"] == 1
        assert manifest["audited_sha"] == sha
        assert manifest["created_at"] == index["created_at"]
        assert manifest["scope"] == scope["scope"]
        assert manifest["report_path"] == scope["report"]
        ids = []
        for finding in manifest["findings"]:
            for key in (
                "id",
                "title",
                "reproduction",
                "root_cause",
                "silent_failure",
                "regression_test",
            ):
                assert text(finding.get(key)), (scope["scope"], key)
            fid = finding["id"]
            assert re.fullmatch(r"[A-Z]{3}-[0-9]{3}", fid), fid
            assert fid.startswith(prefix + "-"), (scope["scope"], fid)
            assert fid not in all_ids, fid
            all_ids.add(fid)
            ids.append(fid)
            assert fid in todo, (fid, "missing TODO")
            assert finding["severity"] in ("critical", "high", "medium", "low")
            assert finding["confidence"] in ("high", "medium", "low")
            guarantees = finding["guarantees"]
            assert isinstance(guarantees, list)
            assert len(set(guarantees)) == len(guarantees)
            assert set(guarantees) <= {"G1", "G2", "G3", "G4", "G5"}
            assert (
                guarantees
                or text(finding.get("confidentiality"))
                or text(finding.get("additional_property"))
            ), fid
            assert finding["source_report"] == scope["report"]
        assert ids == scope["ids"]
    assert len(all_ids) == 26
    for group in index["shared_roots"].values():
        assert len(group) == len(set(group)) and set(group) <= all_ids
    register = load(DIRECTORY / "intentional-differences.json")
    assert register["audited_sha"] == sha
    markdown = (DIRECTORY / "intentional-differences.md").read_text()
    difference_ids = set()
    for entry in register["differences"]:
        assert entry["id"] not in difference_ids
        difference_ids.add(entry["id"])
        assert entry["classification"] in register["classifications"]
        assert set(entry["behavior"]) == {"windows", "macos", "linux"}
        assert all(text(v) for v in entry["behavior"].values()) and text(entry["rationale"])
        assert entry["evidence_reports"]
        assert all((DIRECTORY / p).is_file() for p in entry["evidence_reports"])
        row = next(line for line in markdown.splitlines() if entry["title"] in line)
        assert entry["classification"] in row
    assert len(difference_ids) == 18
    for path in DIRECTORY.rglob("*.ahk"):
        raw = path.read_bytes()
        assert raw.startswith(b"\xef\xbb\xbf") and b"\r" not in raw, path
    documents = [
        ROOT / "README.md",
        ROOT / "TODO.md",
        ROOT / "docs/platform-parity-audit.md",
        *DIRECTORY.rglob("*.md"),
    ]
    for path in documents:
        body = re.sub(r"```[\s\S]*?```", "", path.read_text())
        body = re.sub(r"`[^`\n]*`", "", body)
        for raw in re.findall(r"\]\(([^)\n]+)\)", body):
            target = raw.split("#")[0].strip("<>")
            if target and ":" not in target and not target.startswith("/"):
                assert (path.parent / target).exists(), (path.relative_to(ROOT), target)
    print(
        f"PASS: {len(expected)} scopes, {len(all_ids)} unique OS/flow IDs, {len(difference_ids)} classified behavior entries, schema/TODO/shared-root/evidence/Markdown references."
    )
    print("Metadata and pinned revision only; no native or runtime parity certification.")


if __name__ == "__main__":
    main()
