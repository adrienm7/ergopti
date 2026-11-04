import subprocess, os, pathlib, json

out = pathlib.Path("/workspace/scratch/deep-parity/macos-hotstrings")
lua = "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua"
modules = [
    "tests.unit.modules.dynamic_hotstrings.injection.test_start_transaction",
    "tests.unit.modules.dynamic_hotstrings.injection.test_dynamic_injection_is_private",
    "tests.unit.modules.dynamic_hotstrings.injection.test_prefix_expansion_never_logs_pii",
    "tests.unit.modules.dynamic_hotstrings.injection.test_resolver_failure_visible",
    "tests.unit.modules.dynamic_hotstrings.rules_engine.test_resolver_lifecycle_admission",
    "tests.unit.modules.dynamic_hotstrings.rules_engine.test_rules_engine_start_transaction",
    "tests.unit.modules.dynamic_hotstrings.rules_engine.test_rules_engine_stop_clears_rules",
    "tests.unit.modules.dynamic_hotstrings.rules_engine.test_rules_engine_trigger_char_sync",
    "tests.unit.modules.dynamic_hotstrings.rules_engine.test_rules_engine_utf8_delete_count",
    "tests.unit.modules.dynamic_hotstrings.personal_info.test_personal_info_registry_refresh",
    "tests.unit.modules.dynamic_hotstrings.personal_info.test_personal_info_save_transaction",
    "tests.unit.modules.dynamic_hotstrings.personal_info.test_personal_info_combo_matches_buffer",
    "tests.unit.modules.keymap.eventtap.test_secure_field_pass_through",
    "tests.unit.modules.keymap.eventtap.test_text_destination_ram_snapshot",
    "tests.unit.modules.keymap.eventtap.test_terminal_replacement_off_eventtap",
    "tests.unit.modules.keymap.expansion.test_builtin_clipboard_snapshot_acquisition",
    "tests.unit.modules.keymap.expansion.test_builtin_clipboard_restore_ownership",
    "tests.unit.modules.keymap.expansion.test_clipboard_synthetic_telemetry",
    "tests.unit.modules.keymap.preview.test_preview_provider_failure_visible",
    "tests.unit.modules.keymap.preview.test_preview_winner_expiry_build_race",
    "tests.unit.modules.keymap.preview.test_preview_render_off_hid_thread",
    "tests.unit.modules.keymap.registry.test_registry_mutation_transactions_exact_commitment",
    "tests.unit.modules.keymap.registry.test_registry_mutation_transactions_dynamic_category",
]
results = []
for module in modules:
    env = os.environ.copy()
    env["LUA_CPATH"] = (
        "/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;"
    )
    env["LD_LIBRARY_PATH"] = "/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu"
    env["PATH"] = "/workspace/scratch/parity-toolchain/bin:" + env["PATH"]
    p = subprocess.run(
        [lua, str(out / "run-focused.lua"), module],
        cwd="/workspace/ergopti/static/ergopti_plus/macos",
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    log = out / (module.split(".")[-1] + ".log")
    log.write_text(p.stdout)
    summary = next((s for s in p.stdout.splitlines() if s.startswith("RESULT ")), "NO RESULT")
    results.append(
        {"module": module, "exit_code": p.returncode, "summary": summary, "log": str(log)}
    )
    print(p.returncode, summary, module, flush=True)
(out / "second-pass-results.json").write_text(json.dumps(results, indent=2) + "\n")
