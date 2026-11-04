import pathlib, subprocess, json, re

out = pathlib.Path("/workspace/scratch/parity-flows/macos-clipboard/probes")
root = pathlib.Path("/workspace/ergopti/static/ergopti_plus/macos")
paths = {
    root / x
    for x in [
        "tests/unit/modules/keymap/expansion/test_builtin_clipboard_restore_ownership.lua",
        "tests/unit/modules/keymap/expansion/test_builtin_clipboard_snapshot_acquisition.lua",
        "tests/unit/modules/keymap/expansion/test_emit_tokens_multi_paste.lua",
        "tests/unit/modules/keymap/expansion/test_multi_paste_fifo_handoff.lua",
        "tests/unit/modules/llm/features/test_selection_translation_fifo.lua",
        "tests/unit/modules/llm/features/test_selection_translation_focus_lifecycle.lua",
        "tests/unit/modules/llm/features/test_selection_translation_gate_lifecycle.lua",
        "tests/unit/modules/llm/features/test_selection_translation_scope_ownership.lua",
        "tests/unit/modules/llm/features/test_selection_translation_end_to_end.lua",
        "tests/unit/modules/llm/features/test_tone_rewrite_focus_lifecycle.lua",
        "tests/unit/modules/llm/features/test_tone_rewrite_end_to_end.lua",
        "tests/unit/modules/shortcuts/system_actions/test_screenshot_save_capture_verdicts.lua",
        "tests/unit/adapters/system/test_apple_shortcuts_native.lua",
        "tests/unit/adapters/system/test_apple_shortcuts.lua",
    ]
}
results = []
for path in sorted(paths):
    module = str(path.relative_to(root)).removesuffix(".lua").replace("/", ".")
    p = subprocess.run(
        ["/workspace/scratch/parity-toolchain/ci-bin/lua", str(out / "run-focused.lua"), module],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    log = out / "logs" / (module + ".log")
    log.write_text(p.stdout)
    summary = next((x for x in p.stdout.splitlines() if x.startswith("RESULT ")), "NO RESULT")
    results.append(dict(module=module, exit_code=p.returncode, summary=summary, log=str(log)))
    print(p.returncode, summary, module, flush=True)
(out / "second-test-results.json").write_text(json.dumps(results, indent=2) + "\n")
