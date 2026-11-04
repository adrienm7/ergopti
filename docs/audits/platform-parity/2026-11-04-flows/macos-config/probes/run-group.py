from pathlib import Path
import subprocess, sys, re, json, os

base = Path("/workspace/scratch/parity-flows/macos-config")
modules = sys.argv[2:]
totals = [0, 0]
bad = []
for module in modules:
    p = subprocess.run(
        [
            "/workspace/scratch/parity-toolchain/ci-bin/lua",
            str(base / "probes/run-module.lua"),
            module,
        ],
        cwd="/workspace/ergopti/static/ergopti_plus/macos",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=120,
        env={
            **os.environ,
            "PATH": "/workspace/scratch/parity-toolchain/ci-bin:" + os.environ["PATH"],
        },
    )
    (base / "logs" / (module + ".log")).write_text(p.stdout)
    m = re.search(r"TOTAL (\d+) passed (\d+) failed", p.stdout)
    if m:
        totals = [totals[i] + int(m[i + 1]) for i in range(2)]
    if p.returncode:
        bad.append(module)
    print(module, "PASS" if p.returncode == 0 else "FAIL", m.group(0) if m else p.stdout[-200:])
report = {"modules": modules, "passed": totals[0], "failed": totals[1], "bad_modules": bad}
(base / "logs" / (sys.argv[1] + ".json")).write_text(json.dumps(report, indent=2) + "\n")
print("GROUP", totals, "bad", len(bad))
sys.exit(bool(bad))
