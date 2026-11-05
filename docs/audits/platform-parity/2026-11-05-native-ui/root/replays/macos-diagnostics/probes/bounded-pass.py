import argparse, pathlib, subprocess, json, re

p = argparse.ArgumentParser()
p.add_argument("--source-root", required=True)
p.add_argument("--lua", required=True)
p.add_argument("--node", required=True)
p.add_argument("--artifact-root", required=True)
p.add_argument("--pass-name", required=True)
a = p.parse_args()
r = pathlib.Path(a.source_root)
d = r / "static/ergopti_plus/macos"
b = pathlib.Path(a.artifact_root)
out = b / "logs"
out.mkdir(parents=True, exist_ok=True)
files = sorted((d / "tests/unit/ui/healthcheck").rglob("test_*.lua")) + sorted(
    (d / "tests/unit/modules/diagnostics").glob("test_*.lua")
)
files += [
    d / "tests/unit/infra/logger/test_diagnostic_snapshot.lua",
    d / "tests/unit/infra/logger/test_crash_reporter_wired.lua",
    d / "tests/meta/corpus/test_corpus_healthcheck_snapshot.lua",
    d / "tests/meta/corpus/test_corpus_diagnostics.lua",
    d / "tests/meta/architecture/test_healthcheck_api_contract.lua",
]
rows = []
for f in files:
    selector = ".".join(f.relative_to(d).with_suffix("").parts)
    cmd = [a.lua, str(d / "tests/run.lua"), "--only=" + selector]
    try:
        run = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=120)
        result = run.returncode
        text = run.stdout + run.stderr
    except subprocess.TimeoutExpired as e:
        result = 124
        text = (e.stdout or b"").decode(errors="replace") + "\nTIMED OUT\n"
    log = out / (a.pass_name + "-" + f.stem + ".log")
    log.write_text(text)
    m = re.findall(r"Passed tests:\s*(\d+)", text)
    count = int(m[-1]) if m else None
    rows.append(
        {
            "selector": selector,
            "returncode": result,
            "passed_tests": count,
            "log": str(log),
            "command": cmd,
        }
    )
    print(selector, result, count, flush=True)
for name in [
    "test-diagnostics-redaction-vectors.cjs",
    "test-healthcheck-model.cjs",
    "test-healthcheck-page.cjs",
    "test-error-dialog-page.cjs",
    "test-diagnostic-ui-integrity.cjs",
    "test-diagnostic-snapshot-parity.cjs",
]:
    cmd = [a.node, str(r / "tools/test" / name)]
    run = subprocess.run(cmd, cwd=r, capture_output=True, text=True, timeout=120)
    log = out / (a.pass_name + "-" + name + ".log")
    log.write_text(run.stdout + run.stderr)
    rows.append({"selector": name, "returncode": run.returncode, "log": str(log), "command": cmd})
    print(name, run.returncode, flush=True)
cmd = [a.lua, str(b / "probes/crash-canary.lua"), str(r), str(b)]
run = subprocess.run(cmd, cwd=d, capture_output=True, text=True, timeout=120)
log = out / (a.pass_name + "-crash-canary.log")
log.write_text(run.stdout + run.stderr)
rows.append(
    {
        "selector": "private_crash_canary",
        "returncode": run.returncode,
        "log": str(log),
        "command": cmd,
    }
)
(out / (a.pass_name + "-ledger.json")).write_text(json.dumps(rows, indent=2) + "\n")
raise SystemExit(any(x["returncode"] for x in rows))
