import pathlib, subprocess, json

b = pathlib.Path("/workspace/scratch/parity-recovery/windows-updater")
p = b / "probes"
l = b / "logs"
pw = "/workspace/scratch/parity-toolchain/pwsh-7.4.6/pwsh"
helpers = (p / "actual-swap-helpers.ps1").read_text()
body = (p / "actual-post-parent-swap.ps1").read_text()
port = r"""
function StartReady($Path,$TimeoutMs,$Probation,$AllowLauncherExit){
 $script:Calls++
 $bytes=[IO.File]::ReadAllText($Path)
 $r=@{call=$script:Calls;path=$Path;bytes=$bytes;allow_launcher_exit=[bool]$AllowLauncherExit}
 [IO.File]::AppendAllText($CallsPath,($r|ConvertTo-Json -Compress)+[Environment]::NewLine)
 if(($Case -eq 'primary-failure' -and $script:Calls -eq 1) -or ($Case -eq 'recovery-fallback' -and $script:Calls -le 2)){throw 'controlled native boot-ready refusal'}
 return [pscustomobject]@{SyntheticBoundary=$true}
}
"""
rows = []
for case in ["success", "primary-failure", "recovery-fallback", "stage-missing"]:
    d = p / ("case-" + case)
    d.mkdir(exist_ok=True)
    current = d / "Unicode é current.exe"
    new = d / "new.exe"
    diag = d / "swap.log"
    calls = d / "calls.jsonl"
    for x in d.iterdir():
        if x.is_file():
            x.unlink()
    current.write_text("OLD-GENUINE-FIXTURE")
    if case != "stage-missing":
        new.write_text("NEW-VERIFIED-FIXTURE")
    q = lambda x: "'" + str(x).replace("'", "''") + "'"
    pre = (
        "$ErrorActionPreference='Stop'\n$Case="
        + q(case)
        + "\n$CurrentExe="
        + q(current)
        + "\n$NewExe="
        + q(new)
        + "\n$DiagnosticPath="
        + q(diag)
        + "\n$CallsPath="
        + q(calls)
        + "\n$script:Calls=0\n$BootReadyTimeoutMs=1\n$ProbationMs=0\n$RestoreAttempts=2\n$RestoreRetryMs=0\n"
    )
    script = d / "fixture.ps1"
    script.write_text(
        pre
        + helpers
        + "\n"
        + port
        + "\ntry {\n"
        + body
        + "\n} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }\n"
    )
    out = subprocess.run(
        [pw, "-NoProfile", "-NonInteractive", "-File", str(script)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    (l / (case + ".txt")).write_text(out.stdout)
    records = [json.loads(v) for v in calls.read_text().splitlines()]
    final = current.read_text()
    assert out.returncode == (0 if case == "success" else 1), (case, out.stdout)
    if case == "success":
        assert (
            final == "NEW-VERIFIED-FIXTURE" and len(records) == 1 and records[0]["bytes"] == final
        )
        assert not list(d.glob("*.bak")) and not list(d.glob("*.recovery.exe"))
    elif case in ["primary-failure", "stage-missing"]:
        assert final == "OLD-GENUINE-FIXTURE" and records[-1]["bytes"] == final
        assert not records[-1]["allow_launcher_exit"] and not list(d.glob("*.recovery.exe"))
    else:
        assert (
            final == "OLD-GENUINE-FIXTURE"
            and len(records) == 3
            and records[-1]["allow_launcher_exit"]
        )
        assert (
            records[-1]["bytes"] == "OLD-GENUINE-FIXTURE"
            and len(list(d.glob("*.recovery.exe.claim"))) == 1
        )
    if case != "success":
        assert (d / "swap.log.terminal").read_text().startswith("SWAP_ERROR:")
    row = {
        "case": case,
        "exit_code": out.returncode,
        "canonical_bytes": final,
        "boot_calls": records,
        "verified": True,
    }
    rows.append(row)
    print(json.dumps(row), flush=True)
(l / "swap-cases.json").write_text(json.dumps(rows, indent=2) + "\n")
print("PASS actual_post_parent_swap_cases=4 actual_file_io=true native_process_event_ports=false")
