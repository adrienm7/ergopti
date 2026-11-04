import concurrent.futures, json, os, pathlib, subprocess, time

directory = pathlib.Path("/workspace/scratch/deep-parity/linux-llm")
modules = [
    "ollama.test_api_ollama_terminal_receipt",
    "ollama.test_api_ollama_stream_parse",
    "remote.test_api_remote_callbacks",
    "remote.test_nonchat_probe_isolation",
    "prediction.test_prompt_prediction",
    "prediction.test_live_mode",
    "features.test_tone_selection",
    "features.test_translate_selection",
    "features.test_screen_answers",
    "agent.test_agent_flow",
    "agent.test_agent_auto",
    "agent.test_agent_connector_lifecycle",
    "settings.test_profile_app_overrides",
    "context.test_ai_typing_context",
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
    start = time.monotonic()
    result = subprocess.run(
        [
            "/workspace/scratch/parity-toolchain/lua-5.4.8-dlopen/src/lua",
            str(directory / "run-test.lua"),
            "tests.unit.modules.llm." + module,
        ],
        cwd="/workspace/ergopti",
        env=environment,
        capture_output=True,
        text=True,
        timeout=90,
    )
    (directory / (module + ".log")).write_text(result.stdout + result.stderr)
    summary = next(
        (x for x in result.stdout.splitlines() if x.startswith("AUDIT_TEST_RESULT")), None
    )
    return {
        "module": module,
        "exit_code": result.returncode,
        "summary": summary,
        "seconds": round(time.monotonic() - start, 2),
    }


with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
    results = list(executor.map(run, modules))
(directory / "test-results.json").write_text(json.dumps(results, indent=2) + "\n")
for result in results:
    print(json.dumps(result))
