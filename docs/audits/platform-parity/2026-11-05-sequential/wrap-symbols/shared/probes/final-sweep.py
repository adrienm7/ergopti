import subprocess
import pathlib
import json
import hashlib
import os
import sys

R = pathlib.Path("/workspace/worktrees/parity-sequential-2026-11-05/shared")
ARTIFACT_ROOT = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/wrap-symbols/shared")
label = sys.argv[1]
assert label in ["a", "b"]
env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
log = []


def run(cmd):
    p = subprocess.run(cmd, env=env, cwd=R, capture_output=True, text=True)
    assert p.returncode == 0, (cmd, p.stdout, p.stderr)
    log.append(
        "$ "
        + " ".join(cmd)
        + "\nexit=0 sha256="
        + hashlib.sha256(p.stdout.encode()).hexdigest()
        + "\n"
        + p.stdout.splitlines()[-1]
        + "\n"
    )
    return p.stdout


run(["python3", str(ARTIFACT_ROOT / "probes/build-comparison.py")])
for runtime, name in [("lua5.4", "lua54"), ("luajit", "luajit")]:
    output = run(
        [
            "/workspace/scratch/parity-toolchain/ci-bin/" + runtime,
            str(ARTIFACT_ROOT / "probes/shared-model.lua"),
            str(R),
            str(ARTIFACT_ROOT),
        ]
    )
    assert "TOTAL assertions=283;" in output
    (ARTIFACT_ROOT / ("logs/model-" + name + ".log")).write_text(output)
c = json.loads((ARTIFACT_ROOT / "comparison.json").read_text())
assert (
    len(c["catalogue"]["rows"]) == 43
    and len(c["capabilities"]) == 36
    and len(c["settings"]) == 2
    and len(c["locales"]) == 21
)
assert not c["missing_locale_keys"]
assert len({r["id"] for rows in c["controls"].values() for r in rows if "id" in r}) == 7
assert c["catalogue"]["linux_picker_row_count_source_only"] == 42
assert not json.loads((ARTIFACT_ROOT / "findings.json").read_text())["findings"]
paths = set(sum(c["source_paths"].values(), []))
base = "static/ergopti_plus/_shared/lua/"
paths.update(
    base + p
    for p in [
        "toml_codec/init.lua",
        "toml_codec/codec.lua",
        "toml_codec/leaf_rows.lua",
        "compat/utf8.lua",
        "config_keys.lua",
        "adapter_errors.lua",
        "text_utils/init.lua",
    ]
)
paths.add("docs/audits/platform-parity/2026-11-04-flows/intentional-differences.json")
paths.update(
    str(p.relative_to(R)) for p in (R / "static/ergopti_plus/_shared/data/locales").glob("*.json")
)
inv = {p: hashlib.sha256((R / p).read_bytes()).hexdigest() for p in sorted(paths)}
(ARTIFACT_ROOT / ("logs/source-inventory-" + label + ".json")).write_text(
    json.dumps(inv, indent=2) + "\n"
)
log.append(
    "Whole bounded review: catalogue43/groups7; parameter aliases/order/collisions/Unicode/multichar/empty;2 settings+schema;7 management commands+native alternatives;21 locale projections;36 capabilities; actual preference publication/reentry/stale controls.\n"
)
log.append(
    "OS owner guillemet,macOS filtering,Linux picker omission evidence remains separately owned; no new shared confirmed root. Source inventory="
    + str(len(inv))
    + " files.\n"
)
if label == "b":
    assert inv == json.loads((ARTIFACT_ROOT / "logs/source-inventory-a.json").read_text())
    log.append("Source inventory identical to sweep A.\n")
(ARTIFACT_ROOT / ("logs/sweep-" + label + ".log")).write_text("".join(log))
print(
    "Whole bounded dry sweep "
    + label
    + ":283 assertions/runtime,2 runtimes,43 pairs,7 groups,36 capabilities,2 settings,7 commands,21 locales; no new shared root; hashed files="
    + str(len(inv))
)
