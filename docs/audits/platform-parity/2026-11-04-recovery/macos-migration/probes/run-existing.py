from pathlib import Path
import subprocess, tempfile, os, json

base = Path(__file__).resolve().parent.parent
names = [
    "tests.unit.adapters.test_legacy_folder_migration",
    "tests.unit.infra.config.test_config_paths_managed_bootstrap",
    "tests.unit.infra.config.paths.test_bootstrap_toml",
    "tests.unit.infra.config.test_config_paths_first_launch",
    "tests.unit.infra.config.test_config_paths_home_fallback",
    "tests.unit.infra.config.test_config_paths_write_transaction",
]
rows = []
for name in names:
    with tempfile.TemporaryDirectory(prefix="tmp-suite-", dir=base / "probes") as home:
        result = subprocess.run(
            [
                "/workspace/scratch/parity-toolchain/ci-bin/lua",
                str(base / "probes/run-focused.lua"),
                name,
            ],
            capture_output=True,
            text=True,
            env=dict(os.environ, HOME=home),
        )
        log = base / "logs" / ("suite-" + name + ".txt")
        log.write_text(result.stdout + result.stderr)
        lines = [x for x in result.stdout.splitlines() if x.startswith("RESULT ")]
        rows.append(
            dict(
                module=name,
                exit=result.returncode,
                summary=lines[-1] if lines else None,
                log=str(log),
            )
        )
        print(name, result.returncode, rows[-1]["summary"])
(base / "logs/existing-results.json").write_text(json.dumps(rows, indent=2) + "\n")
assert all(x["exit"] == 0 and x["summary"] for x in rows)
