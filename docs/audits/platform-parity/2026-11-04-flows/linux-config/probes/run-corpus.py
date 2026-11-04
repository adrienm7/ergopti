import os, subprocess, json, pathlib

base = pathlib.Path("/workspace/scratch/parity-flows/linux-config/probes")
root = pathlib.Path("/workspace/ergopti/static/ergopti_plus/linux")
files = []
for folder, pattern in [("infra/config", "test_*.lua"), ("adapters/storage", "test_storage*.lua")]:
    files += list((root / "tests/unit" / folder).glob(pattern))
for rel in [
    "infra/preferences/test_legacy_hotstring_storage.lua",
    "infra/preferences/test_hotstring_preferences.lua",
    "infra/preferences/test_script_settings.lua",
    "infra/scope/test_global_scope.lua",
    "infra/scope/test_config_scope_transaction.lua",
    "infra/scope/test_config_scope_composition.lua",
    "infra/scope/test_config_reset_failure.lua",
    "ui/editors/test_config_cleanup_session.lua",
    "ui/editors/test_config_cleanup_bridge.lua",
    "ui/editors/test_ui_bridge_handlers_paths_editor.lua",
    "ui/editors/test_paths_editor_logs_dir.lua",
    "ui/menu/hotstrings/test_unused_keys_cleanup.lua",
    "ui/menu/about/test_configuration_reset_failure.lua",
]:
    files.append(root / "tests/unit" / rel)
env = os.environ.copy()
env["PATH"] = "/workspace/scratch/parity-toolchain/bin:" + env["PATH"]
env["LD_LIBRARY_PATH"] = "/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu"
env["LUA_CPATH"] = (
    "/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/workspace/scratch/parity-toolchain/modules51/?.so;;"
)
results = []
for p in sorted(set(files)):
    mod = str(p.relative_to(root)).removesuffix(".lua").replace("/", ".")
    out = subprocess.run(
        ["luajit", str(base / "run-focused.lua"), mod],
        cwd=root,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    log = base / "logs" / (p.stem + "-luajit.txt")
    log.write_text(out.stdout)
    results.append(
        {
            "module": mod,
            "exit_code": out.returncode,
            "log": str(log),
            "total": [line for line in out.stdout.splitlines() if line.startswith("TOTAL ")],
        }
    )
    print(out.returncode, mod, results[-1]["total"], flush=True)
(base / "logs" / "corpus-receipt.json").write_text(json.dumps(results, indent=2) + "\n")
print("MODULES", len(results), "FAILED", sum(x["exit_code"] != 0 for x in results))
