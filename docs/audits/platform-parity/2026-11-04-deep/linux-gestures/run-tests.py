import concurrent.futures, json, os, pathlib, subprocess

directory = pathlib.Path("/workspace/scratch/deep-parity/linux-gestures")
modules = [
    "modules.gestures.engine.test_mt_decoder",
    "modules.gestures.engine.test_gesture_direction_vectors",
    "modules.gestures.engine.test_gesture_slot_report",
    "modules.gestures.engine.test_touchpad_finder",
    "modules.gestures.engine.test_touchpad_record",
    "modules.gestures.engine.test_gesture_close_ack",
    "modules.gestures.engine.test_gesture_click_retirement",
    "modules.gestures.config.test_gesture_binding_transaction",
    "modules.gestures.config.test_gesture_enable_transaction",
    "modules.gestures.config.test_gestures_manager_gesture_parameter_binding",
    "modules.gestures.actions.test_workspace_switcher",
    "modules.gestures.actions.test_system_actions",
    "ui.menu.shortcuts.test_gesture_conflicts",
]
environment = os.environ.copy()
environment["LUA_CPATH"] = (
    "/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu/lua/5.4/?.so;/workspace/scratch/parity-toolchain/modules/?.so;;"
)
environment["LD_LIBRARY_PATH"] = (
    "/workspace/scratch/parity-toolchain/debian/usr/lib/x86_64-linux-gnu"
)
environment["PATH"] = "/workspace/scratch/parity-toolchain/bin:" + environment["PATH"]


def run(module):
    result = subprocess.run(
        [
            "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua",
            "/workspace/scratch/deep-parity/linux-llm/run-test.lua",
            "tests.unit." + module,
        ],
        cwd="/workspace/ergopti",
        env=environment,
        capture_output=True,
        text=True,
        timeout=90,
    )
    (directory / (module + ".log")).write_text(result.stdout + result.stderr)
    summary = next(
        (line for line in result.stdout.splitlines() if line.startswith("AUDIT_TEST_RESULT")), None
    )
    return {"module": module, "exit_code": result.returncode, "summary": summary}


with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    results = list(executor.map(run, modules))
(directory / "test-results.json").write_text(json.dumps(results, indent=2) + "\n")
for result in results:
    print(json.dumps(result))
