import pathlib
import json
import re
import subprocess
import os

p = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/wpm/shared")
root = "/workspace/worktrees/parity-sequential-2026-11-05/shared"
r = subprocess.run(
    [
        "/workspace/scratch/parity-toolchain/ci-bin/node",
        root + "/tools/audit/workflow.cjs",
        "validate-report",
        "--report",
        str(p / "findings.json"),
    ],
    capture_output=True,
    text=True,
    cwd=root,
    env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
)
(p / "logs/repository-validator.log").write_text(
    "exit=" + str(r.returncode) + "\n" + r.stdout + r.stderr
)
assert r.returncode != 0 and "report must be inside the repository" in r.stderr + r.stdout
m = json.loads((p / "findings.json").read_text())
c = json.loads((p / "comparison.json").read_text())
coverage = json.loads((p / "coverage.json").read_text())
assert m["schema_version"] == 1 and m["scope"] == "wpm-shared-contract"
assert re.fullmatch("[0-9a-f]{40}", m["audited_sha"]) and m["audited_sha"] == c["audited_sha"]
assert m["created_at"] == "2026-11-05" and (p / m["report_path"]).is_file() and m["findings"] == []
assert len(c["capabilities"]) == len(set(x["id"] for x in c["capabilities"])) == 36
assert {x["id"] for x in c["settings"]} == {
    "wpm_widget_visible",
    "wpm_widget_colors",
    "wpm_widget_graph",
    "wpm_menubar_visible",
    "wpm_menubar_colors",
}
assert {x["id"] for x in c["menu_actions"]} == {
    "wpm_menubar",
    "menubar_colors",
    "wpm_widget",
    "widget_colors",
    "include_realtime",
    "reset_wpm_position",
}
assert all(x["classification"] in c["classification_legend"] for x in c["capabilities"])
assert len(c["reason_text"]) == len(c["locale_units"]) == 21
assert all(len(s["sha256"]) == 64 for s in coverage["sweeps"])
for f in p.rglob("*"):
    if f.is_file():
        assert b"\r\n" not in f.read_bytes(), str(f)
print(
    "Custom brief-schema artifact validation passed. Repository validator rejected intentionally external scratch/custom scope; no repository-gate green claimed."
)
