from pathlib import Path
import json, re, subprocess

root = Path("/workspace/ergopti")
source = (root / "static/ergopti_plus/windows/modules/gestures/system_actions.ahk").read_text(
    encoding="utf-8-sig"
)
match = re.search(
    r"global GESTURE_SYS_EMPTY_TRASH_COMMAND := 'powershell\.exe -NoProfile -NonInteractive -Command \"([^\"]+)\"'",
    source,
)
assert match
body = match[1]
results = []
for refuse in [False, True]:
    prefix = (
        "function Clear-RecycleBin { [CmdletBinding()] param([switch]$Force); "
        + (
            "throw 'recorded native bin refusal'"
            if refuse
            else "Write-Output 'recorded successful bin operation'"
        )
        + " }; "
    )
    run = subprocess.run(
        [
            "/workspace/scratch/parity-toolchain/ci-bin/pwsh",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            prefix + body,
        ],
        capture_output=True,
        text=True,
    )
    assert (run.returncode != 0) == refuse
    results.append(
        {"refuse": refuse, "exit": run.returncode, "stdout": run.stdout, "stderr": run.stderr}
    )
handler = source[
    source.index("GestureSysEmptyTrash(Sys := 0) {") : source.index(
        "; Ejects every removable drive"
    )
]
assert "Sys.Launch(" in handler and "wait" not in handler.lower() and "LoggerInfo(" in handler
out = {
    "source": "213d65af24d2aa4845ba47743c9bab6787b61964",
    "worker_body": body,
    "engine": "PowerShell 7.4.6 Linux; fake native Clear-RecycleBin only",
    "ahk_execution": False,
    "results": results,
    "source_observation": "AHK asks SystemControl.Launch then logs Emptying; launch PID is not retained and no exit callback/monitor exists in handler.",
}
Path("/workspace/scratch/parity-flows/windows-desktop/worker-proof.json").write_text(
    json.dumps(out, indent=2) + "\n"
)
print(
    "PASS: exact worker body, healthy exit0 vs native-refusal exit1; AHK launch receipt observation remains source-only."
)
