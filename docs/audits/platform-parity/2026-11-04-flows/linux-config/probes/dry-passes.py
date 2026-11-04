import os, subprocess, pathlib, json

b = pathlib.Path("/workspace/scratch/parity-flows/linux-config/probes")
e = os.environ.copy()
e.update(
    PATH="/workspace/scratch/parity-toolchain/bin:" + e["PATH"],
    LD_LIBRARY_PATH="/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu",
    LUA_CPATH="/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/workspace/scratch/parity-toolchain/modules51/?.so;;",
)
passes = {
    "dry-pass-1": [
        "infra.config.test_script_config_authority",
        "infra.i18n.test_i18n_persistence",
        "infra.preferences.test_legacy_hotstring_storage",
        "adapters.storage.test_storage_adapter_preserves_corrupt_input",
        "infra.config.test_config_migrate",
        "infra.config.test_config_save_failure",
        "infra.scope.test_config_scope_transaction",
    ],
    "dry-pass-2": [
        "ui.editors.test_config_cleanup_bridge",
        "ui.editors.test_config_cleanup_session",
        "ui.menu.hotstrings.test_unused_keys_cleanup",
        "ui.editors.test_ui_bridge_handlers_paths_editor",
        "ui.editors.test_paths_editor_logs_dir",
        "infra.scope.test_global_scope",
        "infra.scope.test_config_scope_composition",
        "adapters.storage.test_storage_adapter_ordinary_native_cleanup",
        "adapters.storage.test_storage_owned",
    ],
}
results = []
for phase, modules in passes.items():
    for m in modules:
        p = subprocess.run(
            ["luajit", str(b / "run-focused.lua"), "tests.unit." + m],
            cwd="/workspace/ergopti/static/ergopti_plus/linux",
            env=e,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        log = b / "logs" / (phase + "-" + m.rsplit(".", 1)[-1] + ".txt")
        log.write_text(p.stdout)
        row = {
            "phase": phase,
            "module": m,
            "exit_code": p.returncode,
            "totals": [x for x in p.stdout.splitlines() if x.startswith("TOTAL ")],
        }
        results.append(row)
        print(row, flush=True)
(b / "logs" / "dry-passes-receipt.json").write_text(json.dumps(results, indent=2) + "\n")
