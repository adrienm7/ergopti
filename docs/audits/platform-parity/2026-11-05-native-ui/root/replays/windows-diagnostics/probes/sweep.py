import hashlib, json, os, pathlib, subprocess, sys

root = pathlib.Path(os.environ["ERGOPTI_AUDIT_SOURCE_ROOT"]).resolve()
base = pathlib.Path(__file__).resolve().parent.parent
pass_number = int(sys.argv[1])
assert pass_number in (1, 2)
files = list((root / "static/ergopti_plus/windows/ui/healthcheck").glob("*.ahk"))
files += [
    root / p
    for p in (
        "static/ergopti_plus/windows/modules/diagnostics/crash_reporter.ahk",
        "static/ergopti_plus/windows/adapters/crash_report_worker.ahk",
        "static/ergopti_plus/windows/adapters/diagnostics_control.ahk",
        "static/ergopti_plus/windows/infra/diagnostic_snapshot.ahk",
        "static/ergopti_plus/windows/infra/error_report.ahk",
        "static/ergopti_plus/windows/infra/error_net.ahk",
        "static/ergopti_plus/windows/infra/logger.ahk",
        "static/ergopti_plus/windows/ui/error_dialog/init.ahk",
        "static/ergopti_plus/windows/vendor/ergopti_diagnostics.ps1",
        "static/ergopti_plus/windows/vendor/ergopti_crash_worker.ps1",
        "static/ergopti_plus/windows/vendor/ergopti_crash_fallback_worker.ps1",
        "static/ergopti_plus/_shared/ui/healthcheck/script.js",
        "static/ergopti_plus/_shared/ui/healthcheck/model.js",
        "static/ergopti_plus/_shared/ui/error_dialog/script.js",
        "static/ergopti_plus/_shared/modules/diagnostics/schema.json",
        "static/ergopti_plus/_shared/modules/diagnostics/collection.json",
        "static/ergopti_plus/_shared/modules/diagnostics/redaction.json",
    )
]
inventory = [
    {"path": p.relative_to(root).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
    for p in sorted(files)
]
commands = [
    [
        "/workspace/scratch/parity-toolchain/ci-bin/pwsh",
        "-NoLogo",
        "-NoProfile",
        "-File",
        str(base / "probes/resident-projection.ps1"),
    ],
    ["python3", str(base / "probes/crash-partial.py")],
    [
        "/workspace/scratch/parity-toolchain/ci-bin/node",
        str(base / "probes/native-save-source.cjs"),
    ],
]
for command in commands:
    result = subprocess.run(command, capture_output=True, text=True, timeout=50, cwd=root)
    print("COMMAND", json.dumps(command))
    print(result.stdout, end="")
    print(result.stderr, end="")
    if result.returncode:
        raise SystemExit(result.returncode)
receipt = {
    "pass": pass_number,
    "audited_sha": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip(),
    "confirmed_roots": ["WDG-001"],
    "new_roots_after_last_finding": 0,
    "native_windows_executed": False,
    "phases_reviewed": [
        "public diagnostics/control and fallback",
        "snapshot fields and truthful coverage",
        "async probes and cancel refresh",
        "source/session close reopen ownership",
        "typed sharing and export acknowledgements",
        "opt-in day-log canary privacy",
        "native collection status and ZIP evidence custody",
        "error notification and report owners",
        "crash IPC attempt/deadline retirement",
        "primary and fallback crash artifact write failures",
    ],
    "sources": inventory,
}
print("RECEIPT " + json.dumps(receipt))
