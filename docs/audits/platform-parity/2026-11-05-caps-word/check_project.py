"""Exercise bounded audit metadata acceptance and independent rejection controls."""

import copy
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location(
    "caps_word_metadata", Path(__file__).with_name("project.py")
)
project = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(project)


def fixture(directory, populated=True):
    """Create synthetic evidence and one optional finding, without real user data."""
    evidence = [{"path": "proof.txt", "sha256": hashlib.sha256(b"synthetic proof\n").hexdigest()}]
    (directory / "proof.txt").write_bytes(b"synthetic proof\n")
    data = {
        "schema_version": 1,
        "audited_sha": project.AUDITED_SHA,
        "created_at": project.CREATED_AT,
        "module": "caps-word",
        "roles": {},
        "capabilities": [
            {
                "id": "caps-word-contract",
                "contract": "Synthetic bounded contract",
                **{os: "Synthetic owner only" for os in project.ROLES[:3]},
                "availability": {os: "unverified" for os in project.ROLES[:3]},
                "observation_basis": {os: "source" for os in project.ROLES[:3]},
                "classification": "unknown_intent",
                "basis": "Synthetic evidence only",
                "evidence": evidence,
            }
        ],
    }
    for role in project.ROLES:
        report = role + ".md"
        (directory / report).write_text(project.AUDITED_SHA + "\n", encoding="utf-8")
        data["roles"][role] = {
            "report": report,
            "evidence": evidence,
            "findings": [],
            "coverage": [
                {
                    "aspect": "Synthetic aspect",
                    "basis": "source",
                    "qualification": "No runtime observation",
                    "evidence": evidence,
                }
            ],
        }
    if populated:
        data["roles"]["windows"]["findings"] = [
            {
                "id": "TEST-001",
                "title": "Synthetic defect",
                "severity": "medium",
                "confidence": "high",
                "guarantees": ["G2"],
                "reproduction": "Synthetic action",
                "root_cause": "Synthetic mechanism",
                "silent_failure": "Synthetic visibility",
                "regression_test": "Synthetic behavior",
                "basis": "source",
                "qualification": "Not a real finding",
                "evidence": evidence,
            }
        ]
    return data


def command(directory, repo_root, check=False):
    """Run the real command-line boundary with the repository formatter enabled."""
    args = [
        sys.executable,
        str(Path(__file__).with_name("project.py")),
        "--directory",
        str(directory),
        "--repo-root",
        str(repo_root),
    ]
    return subprocess.run(args + (["--check"] if check else []), capture_output=True)


def main():
    """Accept all-zero/populated owners and refuse independently malformed ones."""
    repo_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/workspace/ergopti")
    controls = {
        "wrong SHA": lambda d, p: d.update(audited_sha="0" * 40),
        "wrong date": lambda d, p: d.update(created_at="2026-11-06"),
        "missing role": lambda d, p: d["roles"].pop("linux"),
        "empty role evidence": lambda d, p: d["roles"]["shared"].update(evidence=[]),
        "empty coverage": lambda d, p: d["roles"]["macos"].update(coverage=[]),
        "unknown basis": lambda d, p: d["roles"]["linux"]["coverage"][0].update(
            basis="simulated-native"
        ),
        "missing qualification": lambda d, p: d["roles"]["linux"]["coverage"][0].pop(
            "qualification"
        ),
        "duplicate ID": lambda d, p: d["roles"]["linux"]["findings"].append(
            copy.deepcopy(d["roles"]["windows"]["findings"][0])
        ),
        "bad severity": lambda d, p: d["roles"]["windows"]["findings"][0].update(severity="urgent"),
        "bad confidence": lambda d, p: d["roles"]["windows"]["findings"][0].update(
            confidence="certain"
        ),
        "bad guarantee": lambda d, p: d["roles"]["windows"]["findings"][0].update(
            guarantees=["G9"]
        ),
        "blank root cause": lambda d, p: d["roles"]["windows"]["findings"][0].update(
            root_cause=" "
        ),
        "path traversal": lambda d, p: d["roles"]["linux"].update(report="../outside.md"),
        "missing proof": lambda d, p: (p / "proof.txt").unlink(),
        "digest mismatch": lambda d, p: (p / "proof.txt").write_bytes(b"changed\n"),
        "symlink proof": lambda d, p: (
            (p / "proof.txt").unlink(),
            (p / "proof.txt").symlink_to(p / "windows.md"),
        ),
        "unknown capability finding": lambda d, p: d["capabilities"][0].update(
            finding_ids=["TEST-999"]
        ),
        "unqualified defect": lambda d, p: d["capabilities"][0].update(
            classification="observed_defect"
        ),
        "bad availability": lambda d, p: d["capabilities"][0]["availability"].update(
            linux="certified"
        ),
        "missing OS basis": lambda d, p: d["capabilities"][0]["observation_basis"].pop("macos"),
    }
    with tempfile.TemporaryDirectory(prefix="caps-word-audit-metadata-") as temporary:
        directory = Path(temporary)
        for populated in (False, True):
            data = fixture(directory, populated)
            (directory / "owner.json").write_bytes(project.json_bytes(data))
            project.require(command(directory, repo_root).returncode == 0, "positive generation")
            project.require(command(directory, repo_root, True).returncode == 0, "positive check")
        for name, mutate in controls.items():
            if (directory / "proof.txt").is_symlink():
                (directory / "proof.txt").unlink()
            data = fixture(directory)
            mutate(data, directory)
            try:
                project.validate(data, directory)
            except ValueError:
                continue
            raise AssertionError("accepted malformed control: " + name)
        data = fixture(directory)
        (directory / "owner.json").write_bytes(project.json_bytes(data))
        project.require(command(directory, repo_root).returncode == 0, "restore generation")
        (directory / "index.json").write_bytes(b"{}\n")
        project.require(
            command(directory, repo_root, True).returncode != 0, "stale output accepted"
        )
        (directory / "index.json").unlink()
        (directory / "index.json").symlink_to(directory / "proof.txt")
        project.require(command(directory, repo_root).returncode != 0, "output symlink accepted")
    print(f"metadata controls: 2 positive owners; {len(controls) + 2} negative controls rejected")


if __name__ == "__main__":
    main()
