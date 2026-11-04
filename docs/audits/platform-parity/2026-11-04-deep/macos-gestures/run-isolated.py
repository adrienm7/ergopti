import subprocess, os, pathlib, json

out = pathlib.Path("/workspace/scratch/deep-parity/macos-gestures")
lua = "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua"
modules = [
    "tests.unit.modules.gestures.engine.test_click_drag_is_not_a_gesture",
    "tests.unit.modules.gestures.engine.test_confirmed_drop_rebases_peak",
    "tests.unit.modules.gestures.engine.test_diagonal_reversal",
    "tests.unit.modules.gestures.engine.test_disable_all_releases_clicklock",
    "tests.unit.modules.gestures.engine.test_disable_stops_health_loop",
    "tests.unit.modules.gestures.engine.test_engine",
    "tests.unit.modules.gestures.engine.test_engine_awake_duration",
    "tests.unit.modules.gestures.engine.test_engine_callback_visibility",
    "tests.unit.modules.gestures.engine.test_engine_retap_reversal",
    "tests.unit.modules.gestures.engine.test_engine_stop_releases_scroll_blocker",
    "tests.unit.modules.gestures.engine.test_engine_untrusted_scroll_blocker",
    "tests.unit.modules.gestures.engine.test_finger_count_recovery",
    "tests.unit.modules.gestures.engine.test_finger_upgrade_scroll_guard",
    "tests.unit.modules.gestures.engine.test_frame_clock",
    "tests.unit.modules.gestures.engine.test_gesture_direction_vectors",
    "tests.unit.modules.gestures.engine.test_gesture_suspend_axis",
    "tests.unit.modules.gestures.engine.test_incremental_tab_step",
    "tests.unit.modules.gestures.engine.test_kickstart_respects_pause",
    "tests.unit.modules.gestures.engine.test_mouse_event_provenance",
    "tests.unit.modules.gestures.engine.test_paused_wake_recovery",
    "tests.unit.modules.gestures.engine.test_peak_override_needs_sustained_hold",
    "tests.unit.modules.gestures.engine.test_periodic_logs_on_change",
    "tests.unit.modules.gestures.engine.test_recurring_timer_transaction",
    "tests.unit.modules.gestures.engine.test_scroll_block_respects_enabled",
    "tests.unit.modules.gestures.engine.test_stop_detaches_watchers",
    "tests.unit.modules.gestures.engine.test_stop_force_cleanup",
    "tests.unit.modules.gestures.engine.test_suspend_quiesces_scroll_and_clicklock",
    "tests.unit.modules.gestures.engine.test_three_finger_swipe_stuck",
    "tests.unit.modules.gestures.engine.test_three_finger_swipe_vs_scroll",
    "tests.unit.modules.gestures.engine.test_touch_watcher_lifecycle_transaction",
    "tests.unit.modules.gestures.engine.test_touchdevice_fallback",
    "tests.unit.modules.gestures.config.test_conflicts",
    "tests.unit.modules.gestures.config.test_default_gestures_are_manifest",
    "tests.unit.modules.gestures.config.test_init",
    "tests.unit.modules.gestures.config.test_sensitivity_wrongtype_failclosed",
    "tests.unit.modules.gestures.config.test_system_gesture_conflicts",
    "tests.unit.modules.gestures.actions.test_dispatch_fences",
    "tests.unit.modules.gestures.actions.test_action_confirm",
    "tests.unit.modules.gestures.actions.test_confirmation_lifecycle",
    "tests.unit.modules.gestures.actions.test_composite_resume",
    "tests.unit.modules.gestures.actions.test_actions_aux_pause_ownership",
    "tests.unit.modules.gestures.actions.test_actions_click_acquisition_transaction",
    "tests.unit.modules.gestures.actions.test_user_action_owners",
    "tests.unit.modules.gestures.actions.test_program_completion_status",
    "tests.unit.modules.gestures.actions.test_native_results",
    "tests.unit.modules.gestures.actions.test_action_catalogue_parity",
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
