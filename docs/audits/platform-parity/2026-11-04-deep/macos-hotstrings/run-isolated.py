import subprocess, os, pathlib, json

out = pathlib.Path("/workspace/scratch/deep-parity/macos-hotstrings")
lua = "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua"
modules = [
    "tests.unit.modules.keymap.expansion.test_expander",
    "tests.unit.modules.keymap.expansion.test_hotstring_cascade",
    "tests.unit.modules.keymap.expansion.test_hotstring_cascade_net_edit",
    "tests.unit.modules.keymap.expansion.test_hotstring_final_result",
    "tests.unit.modules.keymap.expansion.test_output_token_vectors",
    "tests.unit.modules.keymap.test_time_gate_corpus",
    "tests.unit.modules.keymap.llm_bridge.test_private_expansion_never_prompted",
    "tests.unit.modules.keymap.preview.test_preview_masks_secrets",
    "tests.unit.modules.keymap.preview.test_preview_never_logs_pii",
    "tests.unit.modules.keymap.preview.test_preview_telemetry_withholds_pii",
    "tests.unit.modules.keymap.preview.test_preview_matches_engine",
    "tests.unit.modules.keymap.preview.test_preview_cross_kind_winner",
    "tests.unit.modules.keymap.preview.test_preview_mutation_commit_gate",
    "tests.unit.modules.keymap.preview.test_preview_row_integrity",
    "tests.unit.modules.dynamic_hotstrings.user_code.test_user_code_native",
    "tests.unit.modules.dynamic_hotstrings.user_code.test_user_code_contract",
    "tests.unit.modules.dynamic_hotstrings.rules_engine.test_rules_engine_preview_snapshot",
    "tests.unit.modules.dynamic_hotstrings.injection.test_dynamic_injection_failure_propagation",
    "tests.unit.modules.dynamic_hotstrings.injection.test_sync_injection",
    "tests.unit.modules.dynamic_hotstrings.injection.test_personal_preview_static_ownership",
    "tests.unit.modules.dynamic_hotstrings.personal_info.test_personal_info_combo_all_or_nothing",
    "tests.unit.modules.dynamic_hotstrings.personal_info.test_personal_info_multifield_no_tab_desync",
    "tests.unit.modules.hotstrings.test_hotstring_bulk_scope",
    "tests.unit.modules.hotstrings.test_hotstrings_config_transaction",
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
(out / "isolated-results.json").write_text(json.dumps(results, indent=2) + "\n")
