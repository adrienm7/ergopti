from pathlib import Path
import subprocess
import re
import json
import hashlib
import os

root = Path("/workspace/worktrees/parity-sequential-2026-11-05/macos")
driver = root / "static/ergopti_plus/macos"
out = Path(__file__).parent
selected = []
for p in sorted((driver / "tests/unit").rglob("test*.lua")):
    s = str(p.relative_to(driver))
    if (
        "/dynamic_hotstrings/personal_info/" in s
        or "personal_info_editor" in s
        or "personal_preview_static_ownership" in s
        or "test_menu_personal_info_source" in s
        or "test_preview_masks_secrets" in s
        or "test_private_expansion_never_prompted" in s
    ):
        selected.append(p)
rows = []
logs = []
for p in selected:
    module = str(p.relative_to(driver)).removesuffix(".lua").replace("/", ".")
    run = subprocess.run(
        ["/workspace/scratch/parity-toolchain/ci-bin/lua5.4", "tests/run.lua", "--only=" + module],
        cwd=driver,
        text=True,
        capture_output=True,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    output = run.stdout + run.stderr
    passed = re.search(r"Passed tests:\s+(\d+)", output)
    failed = re.search(r"Failed tests:\s+(\d+)", output)
    row = {
        "module": module,
        "exit": run.returncode,
        "passed": int(passed[1]) if passed else None,
        "failed": int(failed[1]) if failed else None,
        "full_output_sha256": hashlib.sha256(output.encode()).hexdigest(),
    }
    rows.append(row)
    logs.append(json.dumps(row))
    for line in output.splitlines():
        if "# lua_timing " in line or "FAIL " in line or "Error:" in line:
            logs.append(line)
(out / "registered-isolated.json").write_text(
    json.dumps(
        {
            "modules": rows,
            "total_passed": sum(r["passed"] or 0 for r in rows),
            "total_failed": sum(r["failed"] or 0 for r in rows),
        },
        indent=2,
    )
    + "\n"
)
(out / "registered-isolated.log").write_text("\n".join(logs) + "\n")
print(
    json.dumps(
        {
            "modules": len(rows),
            "pass": sum(r["passed"] or 0 for r in rows),
            "fail": sum(r["failed"] or 0 for r in rows),
            "nonzero_exits": [r["module"] for r in rows if r["exit"]],
        }
    )
)
