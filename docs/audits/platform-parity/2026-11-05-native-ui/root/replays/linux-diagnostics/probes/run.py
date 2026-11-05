import argparse, json, os, pathlib, subprocess, tempfile, time

p = argparse.ArgumentParser()
p.add_argument("--source-root", required=True)
p.add_argument("--pass-id", required=True)
a = p.parse_args()
r = pathlib.Path(a.source_root).resolve()
out = pathlib.Path(__file__).resolve().parent.parent
probes = out / "probes"
assert (
    subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=r, text=True).strip()
    == "3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a"
)
env = os.environ.copy()
env["ERGOPTI_AUDIT_SOURCE_ROOT"] = str(r)
env["PATH"] = (
    "/workspace/scratch/parity-toolchain/ci-bin:/workspace/scratch/parity-toolchain/bin:"
    + env["PATH"]
)
b = r / "static/ergopti_plus"
env["LUA_PATH"] = (
    ";".join(
        str(b / x)
        for x in ["linux/?.lua", "linux/?/init.lua", "_shared/lua/?.lua", "_shared/lua/?/init.lua"]
    )
    + ";;"
)
lua = "/workspace/scratch/parity-toolchain/ci-bin/luajit"
rows = []
modules = []
for folder in ["tests/unit/ui/healthcheck", "tests/unit/modules/diagnostics"]:
    for f in sorted((b / "linux" / folder).glob("test_*.lua")):
        modules.append(".".join(f.relative_to(b / "linux").with_suffix("").parts))
modules += [
    "tests.unit.ui.webview.test_error_dialog_core",
    "tests.unit.ui.webview.test_error_dialog_bridge",
    "tests.unit.ui.editors.test_ui_bridge_handlers_healthcheck_bridge",
    "tests.unit.infra.lifecycle.test_diagnostic_snapshot",
    "tests.unit.infra.lifecycle.test_runtime_diagnostics",
    "tests.meta.corpus.test_corpus_diagnostics",
    "tests.meta.boot.test_error_dialog_wiring",
]


def run(name, cmd, environment=None, preexec=None):
    start = time.monotonic()
    q = subprocess.run(
        cmd,
        cwd=b / "linux",
        env=environment or env,
        text=True,
        capture_output=True,
        timeout=120,
        preexec_fn=preexec,
    )
    (out / "logs" / f"{a.pass_id}-{name}.log").write_text(q.stdout + q.stderr)
    rows.append(
        {
            "name": name,
            "command": cmd,
            "exit_code": q.returncode,
            "seconds": round(time.monotonic() - start, 3),
            "summary": [
                x
                for x in q.stdout.splitlines()
                if x.startswith(("AUDIT_TEST_RESULT", "ADVERSE", "HEALTHY", "REFUSAL", "PRIVACY"))
            ],
        }
    )


with tempfile.TemporaryDirectory(prefix="owned-home-", dir=probes) as home:
    env["HOME"] = home
    env["TMPDIR"] = home
    for name in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"]:
        env[name] = home + "/" + name.lower()
    for module in modules:
        run(module.rsplit(".", 1)[1], [lua, str(probes / "run-test.lua"), str(probes), module])
    run(
        "ai-projection",
        [lua, str(probes / "ai-projection.lua"), str(probes), home, home + "/projection.json"],
    )
    run(
        "page-model",
        [
            "/workspace/scratch/parity-toolchain/ci-bin/node",
            str(probes / "page-model.cjs"),
            home + "/projection.json",
        ],
    )
    for mode in ["partial", "healthy", "refused"]:
        run(
            "http-" + mode,
            [
                lua,
                str(probes / "partial-http.lua"),
                str(probes),
                str(probes / (mode + "-curl")),
                mode,
            ],
        )
    run(
        "api-health",
        [
            lua,
            str(probes / "partial-http.lua"),
            str(probes),
            str(probes / "healthy-curl"),
            "healthy",
            "api",
        ],
    )
    for mode in ["refused", "start-refused", "healthy"]:
        run("timer-" + mode, [lua, str(probes / "timer-admission.lua"), str(probes), mode])
    env["ERGOPTI_DIAGNOSTIC_TEST_LUA"] = lua
    native_env = env.copy()
    native_env["TMPDIR"] = "/tmp"
    run(
        "native-source",
        ["python3", str(b / "linux/tests/hardware/run_diagnostic_source_receipts.py")],
        native_env,
    )
    run(
        "native-save", ["python3", str(b / "linux/tests/hardware/run_diagnostics_save_receipts.py")]
    )
(out / "logs" / f"{a.pass_id}-results.json").write_text(json.dumps(rows, indent=2) + "\n")
print(
    json.dumps(
        {
            "pass": a.pass_id,
            "executions": len(rows),
            "failed": [x["name"] for x in rows if x["exit_code"]],
        }
    )
)
