import json, pathlib, subprocess

directory = pathlib.Path("/workspace/scratch/parity-flows/linux-clipboard")
probes = [
    "clipboard-flows.lua",
    "range-owner.lua",
    "atspi-range-control.lua",
    "file-copy-focus.lua",
]
results = []
for engine in ["lua", "luajit"]:
    version = subprocess.run(
        ["/workspace/scratch/parity-toolchain/ci-bin/" + engine, "-v"],
        capture_output=True,
        text=True,
    )
    for probe in probes:
        result = subprocess.run(
            [
                "/workspace/scratch/parity-toolchain/ci-bin/" + engine,
                str(directory / "probes" / probe),
            ],
            cwd="/workspace/ergopti",
            capture_output=True,
            text=True,
            timeout=30,
        )
        (directory / "logs" / (engine + "-" + probe + ".log")).write_text(
            result.stdout + result.stderr
        )
        results.append(
            dict(
                engine=engine,
                version=(version.stdout + version.stderr).strip(),
                probe=probe,
                exit_code=result.returncode,
            )
        )
(directory / "logs/probe-results.json").write_text(json.dumps(results, indent=2) + "\n")
for result in results:
    print(json.dumps(result))
assert all(result["exit_code"] == 0 for result in results)
