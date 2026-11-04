import pathlib, subprocess, json, re

out = pathlib.Path("/workspace/scratch/parity-flows/macos-clipboard/probes")
root = pathlib.Path("/workspace/ergopti/static/ergopti_plus/macos")
paths = set((root / "tests/unit/modules/shortcuts/text_actions").rglob("test_*.lua"))
paths.update((root / "tests/unit/modules/gestures/actions/clipboard").rglob("test_*.lua"))
for name in [
    "test_search_acquisition",
    "test_search_web_clipboard_restore_retry",
    "test_lookup_transaction",
    "test_wrap_selection_action",
]:
    paths.add(root / ("tests/unit/modules/gestures/actions/" + name + ".lua"))
for folder in ["tests/unit/adapters/storage", "tests/unit/adapters/synthetic_input"]:
    paths.update(p for p in (root / folder).glob("test_*.lua") if "clipboard" in p.name)
for folder in ["tests/unit/modules/shortcuts/system_actions"]:
    paths.update(
        p
        for p in (root / folder).glob("test_*.lua")
        if any(x in p.name for x in ["clipboard", "wrap", "selection"])
    )
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
(out / "test-results.json").write_text(json.dumps(results, indent=2) + "\n")
