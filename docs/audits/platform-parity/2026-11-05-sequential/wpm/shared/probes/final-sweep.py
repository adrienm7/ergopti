import subprocess
import pathlib
import json
import hashlib
import os
import sys

root = pathlib.Path("/workspace/worktrees/parity-sequential-2026-11-05/shared")
out = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/wpm/shared")
label = sys.argv[1]
assert label in ["a", "b"]
env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
log = []


def run(cmd):
    p = subprocess.run(cmd, env=env, cwd=root, capture_output=True, text=True)
    log.append("$ " + " ".join(cmd) + "\n" + p.stdout + p.stderr)
    assert p.returncode == 0, (cmd, p.returncode)
    return p.stdout


run(["python3", str(out / "probes/build-comparison.py")])
for runtime, name in [("lua5.4", "lua54"), ("luajit", "luajit")]:
    output = run(
        [
            "/workspace/scratch/parity-toolchain/ci-bin/" + runtime,
            str(out / "probes/shared-model.lua"),
            str(root),
        ]
    )
    (out / ("logs/model-" + name + ".log")).write_text(output)
    assert "observed policy discrepancies=1; confirmed findings=0" in output
compare = json.loads((out / "comparison.json").read_text())
paths = set()
for d in compare["source_paths"].values():
    paths.update(d.values())
for row in compare["capabilities"]:
    paths.update(row["evidence"])
paths.update(
    [
        "static/ergopti_plus/_shared/modules/timings/constants.toml",
        "static/ergopti_plus/_shared/lua/keystats/live_wpm.lua",
        "static/ergopti_plus/_shared/lua/keystats/metrics.lua",
        "static/ergopti_plus/_shared/core/config_schema/config.schema.json",
        "static/ergopti_plus/_shared/modules/wpm_widget/README.md",
        "static/ergopti_plus/_shared/lua/menu/renderer.lua",
        "static/ergopti_plus/windows/ui/wpm/README.md",
        "static/ergopti_plus/macos/ui/wpm/README.md",
    ]
)
paths.update(
    str(p.relative_to(root))
    for p in (root / "static/ergopti_plus/_shared/data/locales").glob("*.json")
)
inventory = {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sorted(paths)}
(out / ("logs/source-inventory-" + label + ".json")).write_text(
    json.dumps(inventory, indent=2) + "\n"
)
assert (
    len(compare["capabilities"]) == 36
    and len(compare["settings"]) == 5
    and len(compare["menu_actions"]) == 6
)
assert len(compare["locale_units"]) == 21
assert not json.loads((out / "findings.json").read_text())["findings"]
log.append(
    "Scope review: calculation+producer paths; all5 settings; all6 menu commands; all21 unit/reason locales; all36 capability rows; source-only discrepancies and native delivery limits retained.\n"
)
log.append("No new confirmed root. H-WPMS-001 preserved as unknown intent. No next module begun.\n")
log.append("Inventory source files=" + str(len(inventory)) + "\n")
if label == "b":
    previous = json.loads((out / "logs/source-inventory-a.json").read_text())
    assert previous == inventory
    log.append("Source hash inventory identical to sweep A.\n")
(out / ("logs/sweep-" + label + ".log")).write_text("".join(log))
print(
    "Whole bounded-scope sweep "
    + label
    + ": model probes on Lua5.4+LuaJIT; 36 capability rows,5 settings,6 actions,21 locales; no new confirmed root; source files="
    + str(len(inventory))
)
