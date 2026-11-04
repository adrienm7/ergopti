import subprocess, os, pathlib, json

out = pathlib.Path("/workspace/scratch/deep-parity/macos-gestures")
lua = "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua"
modules = [
    "tests.unit.modules.gestures.actions.test_actions_click_mouseup_construction_failure",
    "tests.unit.modules.gestures.actions.test_actions_modifier_keystrokes",
    "tests.unit.modules.gestures.actions.test_gesture_emit_actions",
    "tests.unit.modules.gestures.actions.test_send_input_actions",
    "tests.unit.modules.gestures.actions.test_user_actions",
    "tests.unit.modules.gestures.actions.test_actions_aux_wiring",
    "tests.unit.modules.gestures.actions.test_save_reload",
    "tests.unit.modules.gestures.actions.test_aux_deadline_publication",
    "tests.unit.modules.gestures.navigation.test_native_app_switcher",
    "tests.unit.modules.gestures.navigation.test_native_app_switcher_owner",
    "tests.unit.modules.gestures.navigation.test_native_app_switcher_action",
    "tests.unit.modules.gestures.navigation.test_app_switch_direct",
    "tests.unit.modules.gestures.navigation.test_space_navigation_actions",
    "tests.unit.modules.gestures.navigation.test_open_app_action",
    "tests.unit.ui.menu.gestures_and_apps.test_gesture_scope",
    "tests.unit.ui.menu.shortcuts_and_gestures.test_menu_gesture_conflict_dialog",
    "tests.unit.ui.editors.test_gesture_conflict_notice",
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
