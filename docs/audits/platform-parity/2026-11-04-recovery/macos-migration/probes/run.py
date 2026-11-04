from pathlib import Path
import os, subprocess, tempfile, json

base = Path(__file__).resolve().parent.parent
results = []
for mode in [
    "healthy",
    "rename-refusal",
    "rewrite-refusal",
    "partial-write",
    "nested-override",
    "literal-override",
    "destination-race",
    "symlink-source",
    "native-list-denied",
    "custom-override",
    "destination-clash",
    "occupied-backup",
]:
    with tempfile.TemporaryDirectory(prefix="tmp-", dir=base / "probes") as home:
        env = dict(
            os.environ,
            HOME=home,
            ERGOPTI_PATHS_FILE=home + "/Library/Application Support/Ergopti/paths.toml",
        )
        run = subprocess.run(
            [
                "/workspace/scratch/parity-toolchain/ci-bin/lua",
                str(base / "probes/public-flow.lua"),
                mode,
            ],
            capture_output=True,
            text=True,
            env=env,
        )
        (base / "logs" / f"{mode}.txt").write_text(run.stdout + run.stderr)
        results.append(dict(mode=mode, exit=run.returncode, stdout=run.stdout, stderr=run.stderr))
        print(mode, run.returncode, run.stdout.splitlines()[0] if run.stdout else run.stderr)
(base / "logs/results.json").write_text(json.dumps(results, indent=2) + "\n")
assert all(r["exit"] == 0 for r in results)
