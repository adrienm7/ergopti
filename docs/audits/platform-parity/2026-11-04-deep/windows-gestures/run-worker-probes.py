import subprocess, os, pathlib

p = pathlib.Path(__file__).resolve().parent
pwsh = "/workspace/scratch/parity-toolchain/pwsh-7.4.6/pwsh"
lines = []
for worker in ["onboarding", "restart"]:
    for scenario in ["ok", "none", "disable_fail", "enable_fail"]:
        for file in ["worker.result", "worker.result.stage"]:
            (p / file).unlink(missing_ok=True)
        env = dict(os.environ, ERGOPTI_GESTURE_SCENARIO=scenario)
        r = subprocess.run(
            [
                pwsh,
                "-NoLogo",
                "-NoProfile",
                "-File",
                str(p / "fake-native.ps1"),
                str(p / f"worker-{worker}.ps1"),
            ],
            env=env,
            text=True,
            capture_output=True,
        )
        token = (p / "worker.result").read_text() if (p / "worker.result").exists() else "<missing>"
        lines.append(
            f"{worker:10s} scenario={scenario:12s} process_exit={r.returncode} published_result={token}"
        )
        expected = "0" if worker == "onboarding" or scenario == "ok" else "1"
        assert token == expected, (worker, scenario, r.stdout, r.stderr, token)
        assert r.returncode == int(expected), (worker, scenario, r.returncode, r.stderr)
(p / "worker-output.txt").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
