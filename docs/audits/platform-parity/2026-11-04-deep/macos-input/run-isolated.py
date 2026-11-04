import subprocess, os, pathlib, json

out = pathlib.Path("/workspace/scratch/deep-parity/macos-input")
lua = "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua"
modules = [
    "tests.unit.platform.remap.generator.test_generator_combos_without_tap_holds",
    "tests.unit.platform.remap.generator.test_generator_tap_holds_switch",
    "tests.unit.platform.remap.generator.test_generator_layers",
    "tests.unit.platform.remap.generator.test_generator_nav_layer",
    "tests.unit.platform.remap.rules.test_layer_variable_single_authority",
    "tests.unit.platform.remap.rules.test_tap_hold_key_thresholds",
    "tests.unit.platform.remap.rules.test_nav_layer_rule",
    "tests.unit.platform.remap.generator.test_generator_typing_rollover",
    "tests.unit.platform.remap.generator.test_generator_owned_deploy",
    "tests.unit.platform.remap.runtime_owner.test_runtime_dormant",
    "tests.unit.adapters.runtime_capture.test_runtime_capture_port",
    "tests.unit.modules.shortcuts.magic_editor.test_magic_editor_source_owner_native",
    "tests.unit.modules.shortcuts.magic_editor.test_magic_editor_source_owner_original",
    "tests.unit.platform.remap.enable_transaction.test_scope_owner_navigation_layer",
]
results = []
for module in modules:
    env = os.environ.copy()
    env["LUA_CPATH"] = "/workspace/scratch/parity-toolchain/modules/?.so;;"
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
    print(p.returncode, summary, module)
(out / "isolated-results.json").write_text(json.dumps(results, indent=2) + "\n")
