"""Exercise artifact rejection controls exclusively in temporary fixtures."""

import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
DIRECTORY = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("sequential_validator", DIRECTORY / "validate.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


def write_json(path, data):
    """Write a synthetic JSON owner with explicit LF bytes."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes((json.dumps(data, indent=2) + "\n").encode("utf-8"))


def fixture(root, populated=True):
    """Construct all bounded scopes with no dependency on active campaign data."""
    campaign = root / "campaign"
    base = {
        "schema_version": 1,
        "audited_sha": validator.AUDITED_SHA,
        "created_at": validator.CREATED_AT,
    }
    index = dict(base, module_order=list(validator.MODULES), modules=[], shared_mechanisms={})
    phases = {"audited_sha": validator.AUDITED_SHA, "phases": []}
    capabilities = dict(base, modules=[])
    for number, module in enumerate(validator.MODULES):
        index_module = {"module": module, "scopes": []}
        index["modules"].append(index_module)
        phases["phases"].append(
            {
                "module": module,
                "state": "bounded_review_closed",
                "started_utc": f"2026-11-05T0{number * 2}:00:00+00:00",
                "closed_utc": f"2026-11-05T0{number * 2 + 1}:00:00+00:00",
            }
        )
        capabilities["modules"].append(
            {
                "module": module,
                "capabilities": [
                    {
                        "id": module + "-contract",
                        "contract": "Synthetic bounded contract",
                        "windows": "Source-only",
                        "macos": "Synthetic seam",
                        "linux": "Synthetic seam",
                        "classification": "unknown_intent",
                        "basis": "Fixture evidence only",
                        "evidence": [module + "/windows/report.md"],
                    }
                ],
            }
        )
        for role in validator.ROLES:
            owner = campaign / module / role
            owner.mkdir(parents=True)
            canonical = owner.relative_to(root).as_posix()
            report = canonical + "/report.md"
            (owner / "report.md").write_bytes((validator.AUDITED_SHA + "\n").encode())
            findings = []
            if populated and module == "wpm" and role == "windows":
                (owner / "proof.log").write_bytes(b"synthetic proof\n")
                findings = [
                    {
                        "id": "TEST-001",
                        "title": "Synthetic defect",
                        "severity": "medium",
                        "confidence": "high",
                        "guarantees": ["G2"],
                        "reproduction": "Synthetic reproduction",
                        "root_cause": "Synthetic cause",
                        "silent_failure": "Synthetic backstop",
                        "regression_test": "Synthetic controls",
                        "source_report": report,
                        "basis": "Synthetic fixture",
                        "evidence": ["proof.log"],
                    }
                ]
            scope = {
                "role": role,
                "report": report,
                "manifest": canonical + "/findings.json",
                "ids": [f["id"] for f in findings],
            }
            index_module["scopes"].append(scope)
            write_json(
                owner / "findings.json",
                dict(base, scope=module + "-" + role, report_path=report, findings=findings),
            )
    write_json(campaign / "index.json", index)
    write_json(campaign / "source.json", dict(base, module_order=list(validator.MODULES)))
    write_json(campaign / "phases.json", phases)
    write_json(campaign / "capabilities.json", capabilities)
    (root / "TODO.md").write_bytes(b"- [ ] TEST-001 synthetic open work\n")
    (campaign / "capabilities.md").write_bytes(
        validator.renderer().render(capabilities, validator.ROOT).encode()
    )
    # Formatter availability is supplied by the real repository, not copied.
    (root / "node_modules").symlink_to(validator.ROOT / "node_modules", target_is_directory=True)
    return campaign


def reject(name, mutate):
    """Require a targeted malformed fixture to fail closed."""
    with tempfile.TemporaryDirectory(prefix="sequential-validator-") as temporary:
        root = Path(temporary)
        campaign = fixture(root)
        mutate(campaign, root)
        try:
            validator.validate(campaign, root, check_source=False)
        except (ValueError, KeyError, TypeError):
            print("PASS rejection:", name)
        else:
            raise RuntimeError("Validator accepted " + name)


def edit(path, mutate):
    """Mutate one JSON fixture owner without touching campaign artifacts."""
    data = json.loads(path.read_text(encoding="utf-8"))
    mutate(data)
    write_json(path, data)


def finding(campaign, mutate):
    """Change the single populated synthetic manifest."""
    edit(campaign / "wpm/windows/findings.json", mutate)


def main():
    """Prove healthy and zero-ID acceptance, plus required rejection controls."""
    for populated in (True, False):
        with tempfile.TemporaryDirectory(prefix="sequential-validator-") as temporary:
            root = Path(temporary)
            campaign = fixture(root, populated)
            count = validator.validate(campaign, root, check_source=False)
            validator.require(count == int(populated), "fixture count")
            print(
                "PASS acceptance:",
                "one finding" if populated else "all twelve scopes have zero findings",
            )
    reject("missing evidence", lambda c, r: (c / "wpm/windows/proof.log").unlink())
    reject(
        "wrong SHA", lambda c, r: edit(c / "source.json", lambda d: d.update(audited_sha="0" * 40))
    )
    reject(
        "duplicate IDs",
        lambda c, r: finding(c, lambda d: d["findings"].append(copy.deepcopy(d["findings"][0]))),
    )
    reject("TODO substring is not an ID", lambda c, r: (r / "TODO.md").write_bytes(b"TEST-0010\n"))
    reject(
        "invalid guarantee",
        lambda c, r: finding(c, lambda d: d["findings"][0].update(guarantees=["G6"])),
    )
    reject(
        "invalid classification",
        lambda c, r: edit(
            c / "capabilities.json",
            lambda d: d["modules"][0]["capabilities"][0].update(classification="intent_assumed"),
        ),
    )
    reject(
        "sequence inversion",
        lambda c, r: edit(
            c / "phases.json",
            lambda d: d["phases"][1].update(started_utc="2026-11-05T00:30:00+00:00"),
        ),
    )
    reject("table drift", lambda c, r: (c / "capabilities.md").write_bytes(b"stale table\n"))
    reject(
        "scope path escape",
        lambda c, r: finding(
            c, lambda d: d["findings"][0].update(evidence=["../windows/proof.log"])
        ),
    )
    reject(
        "CRLF evidence", lambda c, r: (c / "wpm/windows/proof.log").write_bytes(b"synthetic\r\n")
    )
    reject(
        "wrong index scope",
        lambda c, r: edit(
            c / "index.json", lambda d: d["modules"][0]["scopes"][0].update(role="elsewhere")
        ),
    )


if __name__ == "__main__":
    main()
