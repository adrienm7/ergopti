import pathlib
import json
import re
import subprocess
import os

p = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/wrap-symbols/shared")
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
assert (
    m["schema_version"] == 1
    and m["scope"] == "wrap-symbols-shared-contract"
    and m["findings"] == []
)
assert (
    re.fullmatch("[0-9a-f]{40}", m["audited_sha"])
    and m["audited_sha"] == c["audited_sha"] == v["audited_sha"]
)
assert m["created_at"] == "2026-11-05" and (p / m["report_path"]).is_file()
assert len(c["catalogue"]["rows"]) == 43 and len(c["catalogue"]["groups"]) == 7
assert len(c["capabilities"]) == len({x["id"] for x in c["capabilities"]}) == 36
assert all(x["classification"] in c["classification_legend"] for x in c["capabilities"])
assert len(c["settings"]) == 2 and all(
    x["default"] is False and x["recommended"] is True for x in c["settings"]
)
assert len(c["locales"]) == 21 and not c["missing_locale_keys"]
assert len([x for arr in c["controls"].values() for x in arr if x.get("id")]) == 7
assert all(len(s["sha256"]) == 64 for s in v["sweeps"])
for f in p.rglob("*"):
    if f.is_file():
        assert b"\r\n" not in f.read_bytes(), str(f)
print(
    "PASS brief-schema validation:manifest/report/coverage/comparison,43 rows,7 groups,36 capabilities,2 settings,7 commands,21 locales,LF artifacts. Repository validator external-path rejection retained; no false gate green."
)
