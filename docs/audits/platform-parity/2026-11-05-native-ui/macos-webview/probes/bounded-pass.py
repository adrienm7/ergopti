import argparse, pathlib, subprocess, json

p = argparse.ArgumentParser()
p.add_argument("--source-root", required=True)
p.add_argument("--lua", required=True)
p.add_argument("--node", required=True)
p.add_argument("--log-dir", required=True)
p.add_argument("--pass-name", required=True)
a = p.parse_args()
r = pathlib.Path(a.source_root)
d = r / "static/ergopti_plus/macos"
out = pathlib.Path(a.log_dir)
out.mkdir(parents=True, exist_ok=True)
selectors = [
    "tests.unit.ui.menu.gestures_and_apps.test_program_provider_picker",
    "tests.unit.ui.menu.gestures_and_apps.test_automation_inventory",
    "tests.unit.ui.action_picker.lifecycle.test_controller_pool_leases",
    "tests.unit.ui.action_picker.lifecycle.test_controller_retention",
    "tests.unit.ui.ui_builder.lifecycle.test_webview_close_recursion",
    "tests.unit.adapters.system.test_webview_result",
    "tests.unit.ui.hotstring_windows.test_hotstrings_config_window_owners",
    "tests.unit.ui.hotstring_windows.test_hotstrings_config_window_transaction",
    "tests.unit.ui.hotstring_windows.test_hotstrings_config_window_javascript",
    "tests.unit.ui.hotstring_windows.test_hotstrings_config_window_section_boundary",
    "tests.unit.ui.hotstring_windows.test_hotstring_editor_owners",
    "tests.unit.ui.hotstring_windows.test_hotstring_editor_unreadable_source",
    "tests.unit.ui.hotstring_windows.test_hotstring_editor_save_validation",
    "tests.unit.ui.hotstring_windows.test_hotstring_editor_javascript",
    "tests.unit.ui.editors.test_personal_info_editor_owner_callbacks",
    "tests.unit.ui.editors.test_personal_info_editor_close_transaction",
    "tests.unit.ui.editors.test_personal_info_editor_construction",
]
rows = []
for s in selectors:
    cmd = [a.lua, str(d / "tests/run.lua"), "--only=" + s]
    run = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=120)
    log = out / (a.pass_name + "-" + s.rsplit(".", 1)[-1] + ".log")
    log.write_text(run.stdout + run.stderr)
    rows.append({"selector": s, "returncode": run.returncode, "log": str(log), "command": cmd})
    print(s, run.returncode, flush=True)
cmd = [a.lua, str(pathlib.Path(__file__).parent / "receipts.lua"), str(r)]
run = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=120)
log = out / (a.pass_name + "-receipts.log")
log.write_text(run.stdout + run.stderr)
rows.append(
    {"selector": "private_receipts", "returncode": run.returncode, "log": str(log), "command": cmd}
)
cmd = [
    a.lua,
    str(pathlib.Path(__file__).parent / "autoclose-host.lua"),
    str(r),
    a.node,
    str(out.parent),
]
run = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=120)
log = out / (a.pass_name + "-autoclose.log")
log.write_text(run.stdout + run.stderr)
rows.append(
    {
        "selector": "private_autoclose_join",
        "returncode": run.returncode,
        "log": str(log),
        "command": cmd,
    }
)
(out / (a.pass_name + "-ledger.json")).write_text(json.dumps(rows, indent=2) + "\n")
raise SystemExit(any(row["returncode"] for row in rows))
