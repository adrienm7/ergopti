from pathlib import Path
import subprocess, json, tempfile, shutil, sys

base = Path(__file__).resolve().parents[1]
engine = "/workspace/scratch/parity-toolchain/ci-bin/" + sys.argv[1]
pass_id = sys.argv[2]
commands = [
    [engine, str(base / "probes/native.lua"), case]
    for case in (
        "healthy",
        "race",
        "newline",
        "refused_rename",
        "override",
        "alias",
        "symlink",
        "backup_retry",
        "name_controls",
        "parent_refusal",
        "cache_refusal",
    )
]
commands.append([engine, str(base / "probes/registered.lua")])
r = tempfile.mkdtemp(prefix="permission-", dir=base / "probes")
commands.append([engine, str(base / "probes/list-permission.lua"), r])
results = []
try:
    for i, command in enumerate(commands):
        p = subprocess.run(
            command, cwd="/workspace/ergopti", capture_output=True, text=True, timeout=30
        )
        log = base / "logs" / f"{pass_id}-{i:02}.txt"
        log.write_text(p.stdout + p.stderr)
        results.append({"command": command, "exit": p.returncode, "log": str(log)})
        if p.returncode:
            print(log.read_text())
            raise RuntimeError(command)
finally:
    shutil.rmtree(r)
receipt = {
    "pass": pass_id,
    "engine": engine,
    "results": results,
    "status": "passed",
    "new_confirmed_roots": 0,
}
(base / "logs" / f"{pass_id}.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(pass_id, "commands", len(results), "all passed")
