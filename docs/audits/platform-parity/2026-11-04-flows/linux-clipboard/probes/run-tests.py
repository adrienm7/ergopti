import concurrent.futures, json, pathlib, subprocess

directory = pathlib.Path("/workspace/scratch/parity-flows/linux-clipboard")
modules = [
    "adapters.synthetic_input.test_clipboard_selection_transaction",
    "adapters.synthetic_input.test_clipboard_failure_atomic",
    "adapters.synthetic_input.test_clipboard_partial_write",
    "adapters.synthetic_input.test_clipboard_snapshot_restorability",
    "adapters.synthetic_input.test_clipboard_prepared_stage",
    "adapters.synthetic_input.test_selection_write_owner",
    "modules.shortcuts.text_actions.test_selection_action_destination",
    "modules.shortcuts.text_actions.test_wrap_output_owner",
    "modules.shortcuts.text_actions.test_wrap_on_type",
    "modules.shortcuts.text_actions.test_case_transforms",
    "modules.shortcuts.text_actions.test_text_case_vectors",
    "modules.shortcuts.text_actions.test_wrap_pair_parameter_vectors",
    "modules.shortcuts.actions.test_open_selection",
    "modules.gestures.actions.test_file_selection_vectors",
    "infra.text.test_text_case",
]


def run(item):
    engine, module = item
    result = subprocess.run(
        [
            "/workspace/scratch/parity-toolchain/ci-bin/" + engine,
            str(directory / "probes/run-one.lua"),
            "tests.unit." + module,
        ],
        cwd="/workspace/ergopti",
        capture_output=True,
        text=True,
        timeout=120,
    )
    (directory / "logs" / (engine + "-" + module + ".log")).write_text(
        result.stdout + result.stderr
    )
    summary = next(
        (line for line in result.stdout.splitlines() if line.startswith("AUDIT_RESULT")), None
    )
    return dict(engine=engine, module=module, exit_code=result.returncode, summary=summary)


with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    results = list(
        executor.map(run, [(engine, module) for engine in ["lua", "luajit"] for module in modules])
    )
(directory / "logs/test-results.json").write_text(json.dumps(results, indent=2) + "\n")
for result in results:
    print(json.dumps(result))
