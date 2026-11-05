import subprocess
import pathlib
import json
import hashlib
import os
import sys

R = pathlib.Path("/workspace/worktrees/parity-sequential-2026-11-05/shared")
ARTIFACT_ROOT = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/personal-info/shared")
label = sys.argv[1]
assert label in ["a", "b"]
env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
log = []


def run(cmd, name=None):
    p = subprocess.run(cmd, env=env, cwd=R, capture_output=True, text=True)
    assert p.returncode == 0, (cmd, p.stdout, p.stderr)
    if name:
        (ARTIFACT_ROOT / ("logs/" + name + ".log")).write_text(p.stdout + p.stderr)
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
        ],
        "model-" + name,
    )
    assert "TOTAL assertions=108;" in output and "CONTRACT_MISMATCH PIS-001" in output
output = run(
    [
        "/workspace/scratch/parity-toolchain/ci-bin/luajit",
        str(ARTIFACT_ROOT / "probes/prefix-count-owner.lua"),
        str(R),
        str(ARTIFACT_ROOT),
    ],
    "prefix-count-owner",
)
assert "prefix_mappings=2 active_count=4" in output
output = run(
    [
        "/workspace/scratch/parity-toolchain/ci-bin/node",
        str(ARTIFACT_ROOT / "probes/frontend.cjs"),
        str(R),
        str(ARTIFACT_ROOT),
    ],
    "frontend",
)
assert "assertions=39;" in output
c = json.loads((ARTIFACT_ROOT / "comparison.json").read_text())
m = json.loads((ARTIFACT_ROOT / "findings.json").read_text())
assert (
    len(c["field_catalogue"]) == 15
    and len(c["capabilities"]) == 42
    and len(c["feature_settings"]) == 4
    and len(c["locales"]) == 21
)
assert (
    len(m["findings"]) == 1
    and m["findings"][0]["id"] == "PIS-001"
    and m["findings"][0]["guarantees"] == []
)
assert len(c["missing_locale_keys"]) == 21 and all(
    x == ["menu.hotstrings.dynamic.text_expansion_personal_information"]
    for x in c["missing_locale_keys"].values()
)
paths = set(sum(c["source_paths"].values(), []))
base = "static/ergopti_plus/_shared/lua/"
paths.update(
    base + p
    for p in [
        "toml_codec/init.lua",
        "toml_codec/codec.lua",
        "compat/utf8.lua",
        "config_keys.lua",
        "text_utils/init.lua",
    ]
)
paths.update(
    [
        "TODO.md",
        "docs/audits/platform-parity/2026-11-04/hotstrings.md",
        "docs/audits/platform-parity/2026-11-04-flows/intentional-differences.json",
    ]
)
paths.update(
    str(p.relative_to(R)) for p in (R / "static/ergopti_plus/_shared/data/locales").glob("*.json")
)
inv = {p: hashlib.sha256((R / p).read_bytes()).hexdigest() for p in sorted(paths)}
(ARTIFACT_ROOT / ("logs/source-inventory-" + label + ".json")).write_text(
    json.dumps(inv, indent=2) + "\n"
)
log.append(
    "Whole bounded review:15fields/4secret-preview/13aliases;42capabilities;4feature families/schema1..16;editor+fileaction;21locale projections (one metadata-only key missing in all21);108 assertions on eachLua;actualmanager4vs2;frontend39assertions.\n"
)
log.append(
    "Known phone/magic gaps and prior config/editor/crypto roots deduplicated. Native GUI unrun. No new shared root after PIS-001; sourcefiles="
    + str(len(inv))
    + "\n"
)
if label == "b":
    assert inv == json.loads((ARTIFACT_ROOT / "logs/source-inventory-a.json").read_text())
    log.append("Source inventory identical to sweep A.\n")
(ARTIFACT_ROOT / ("logs/sweep-" + label + ".log")).write_text("".join(log))
print(
    "Whole bounded dry sweep "
    + label
    + ":42 capabilities/15 fields/4 features/21 locales;108 assertions perLua,actualmanager prefix2/count4,frontend39; no new shared root; sourcefiles="
    + str(len(inv))
)
