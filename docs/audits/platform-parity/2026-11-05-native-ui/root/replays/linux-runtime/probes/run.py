import os, pathlib, subprocess, tempfile, json, argparse

p = argparse.ArgumentParser()
p.add_argument("--source-root", required=True)
p.add_argument("--pass-id", required=True)
a = p.parse_args()
r = pathlib.Path(a.source_root).resolve()
out = pathlib.Path(__file__).resolve().parent.parent
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
env["LUA_PATH"] = (
    str(r / "static/ergopti_plus/linux/?.lua")
    + ";"
    + str(r / "static/ergopti_plus/linux/?/init.lua")
    + ";"
    + str(r / "static/ergopti_plus/_shared/lua/?.lua")
    + ";"
    + str(r / "static/ergopti_plus/_shared/lua/?/init.lua")
    + ";;"
)
modules = []
base = r / "static/ergopti_plus/linux/tests/unit/modules/llm"
for directory in ["runtime", "ollama"]:
    for f in sorted((base / directory).glob("test_*.lua")):
        if directory == "runtime" or any(x in f.name for x in ["install", "archive", "retained"]):
            modules.append("tests.unit.modules.llm." + directory + "." + f.stem)
for name in [
    "test_owned_process",
    "test_owned_process_close_attempts",
    "test_owned_process_deadline",
    "test_owned_process_running",
    "test_process_lifecycle",
    "test_process_runner",
]:
    modules.append("tests.unit.adapters.processes." + name)
for f in sorted((r / "static/ergopti_plus/linux/tests/unit/infra/archive").glob("test_*.lua")):
    modules.append("tests.unit.infra.archive." + f.stem)
for name in ["test_ollama_pinned_artifact", "test_ollama_zstd_feed"]:
    modules.append("tests.unit.infra.native_artifacts." + name)
modules.append("tests.unit.adapters.network.test_tcp_probe")
rows = []


def run(name, cmd):
    q = subprocess.run(cmd, cwd=r, env=env, text=True, capture_output=True, timeout=90)
    (out / "logs" / f"{a.pass_id}-{name}.log").write_text(q.stdout + q.stderr)
    rows.append(
        {
            "name": name,
            "command": cmd,
            "exit_code": q.returncode,
            "summary": [
                x
                for x in q.stdout.splitlines()
                if "AUDIT_TEST_RESULT" in x
                or x.startswith(("ADVERSE", "HEALTHY", "REFUSAL", "VISIBILITY"))
            ],
        }
    )


for module in modules:
    run(
        module.split(".")[-1],
        [
            "/workspace/scratch/parity-toolchain/ci-bin/luajit",
            str(out / "probes/run-test.lua"),
            module,
        ],
    )
with tempfile.TemporaryDirectory(prefix="owned-state-", dir=out / "probes") as fixture:
    run(
        "state-cache",
        [
            "/workspace/scratch/parity-toolchain/ci-bin/luajit",
            str(out / "probes/state-cache.lua"),
            fixture,
        ],
    )
run(
    "native-files",
    [
        "python3",
        str(r / "static/ergopti_plus/linux/tests/hardware/run_ollama_install_files_native.py"),
        str(r / "static/ergopti_plus/linux"),
        "--lua",
        "/workspace/scratch/parity-toolchain/ci-bin/luajit",
    ],
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
