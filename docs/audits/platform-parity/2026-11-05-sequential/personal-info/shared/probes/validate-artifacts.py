import pathlib
import json
import re
import subprocess
import os

p = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/personal-info/shared")
r = pathlib.Path("/workspace/worktrees/parity-sequential-2026-11-05/shared")
check = subprocess.run(
    [
        "/workspace/scratch/parity-toolchain/ci-bin/node",
        str(r / "tools/audit/workflow.cjs"),
        "validate-report",
        "--report",
        str(p / "findings.json"),
    ],
    cwd=r,
    capture_output=True,
    text=True,
    env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
)
(p / "logs/repository-validator.log").write_text(
    "exit=" + str(check.returncode) + "\n" + check.stdout + check.stderr
)
assert (
    check.returncode != 0 and "report must be inside the repository" in check.stdout + check.stderr
)
m = json.loads((p / "findings.json").read_text())
c = json.loads((p / "comparison.json").read_text())
v = json.loads((p / "coverage.json").read_text())
assert m["schema_version"] == 1 and m["scope"] == "personal-info-shared-contract"
assert (
    re.fullmatch("[0-9a-f]{40}", m["audited_sha"])
    and m["audited_sha"] == c["audited_sha"] == v["audited_sha"]
)
assert m["created_at"] == "2026-11-05" and (p / m["report_path"]).is_file()
assert len(m["findings"]) == 1 and m["findings"][0]["id"] == "PIS-001"
f = m["findings"][0]
assert (
    f["guarantees"] == []
    and f["additional_properties"]["truthful_status"]
    and f["severity"] == "low"
    and f["confidence"] == "high"
)
for key in ["title", "reproduction", "root_cause", "silent_failure", "regression_test"]:
    assert isinstance(f[key], str) and f[key]
for e in f["evidence"]:
    assert (p / e).is_file(), e
assert len(c["field_catalogue"]) == 15 and sum(x["masked"] for x in c["field_catalogue"]) == 4
assert len(c["capabilities"]) == len({x["id"] for x in c["capabilities"]}) == 42
assert all(x["classification"] in c["classification_legend"] for x in c["capabilities"])
assert (
    len(c["feature_settings"]) == 4 and len(c["example_aliases"]) == 13 and len(c["locales"]) == 21
)
assert len(c["missing_locale_keys"]) == 21 and all(
    x == ["menu.hotstrings.dynamic.text_expansion_personal_information"]
    for x in c["missing_locale_keys"].values()
)
assert all(len(s["sha256"]) == 64 for s in v["sweeps"])
for path in p.rglob("*"):
    if path.is_file():
        assert b"\r\n" not in path.read_bytes(), str(path)
print(
    "PASS brief-schema artifacts:one low PIS-001 additional truthful_status property/no forced G;15fields/42capabilities/4features/13aliases/21locales;metadata-only locale omission preserved;LF. Repository externalpath rejection retained,not green."
)
