import subprocess, pathlib, json

b = pathlib.Path("/workspace/scratch/parity-recovery/windows-updater")
root = "/workspace/ergopti"
p = "/workspace/scratch/parity-toolchain/pwsh-7.4.6/pwsh"
st = root + "/static/ergopti_plus/windows/vendor/ergopti_updater_staging.ps1"
mod = root + "/static/ergopti_plus/windows/vendor/ergopti_updater_download.ps1"
commands = []
for t in [
    "test-release-install-contract.cjs",
    "test-changelog-release-install.cjs",
    "test-updater-copy-before-consent.cjs",
    "test-updater-copy-is-shown.cjs",
    "test-updater-constants-single-source.cjs",
]:
    commands.append((t, ["npx", "--yes", "--package=node@22.22.2", "node", "tools/test/" + t], 0))
commands.append(
    (
        "staging-closure",
        [
            p,
            "-NoProfile",
            "-File",
            "tools/test/test_updater_staging_closure.ps1",
            "-WorkerSourcePath",
            st,
        ],
        0,
    )
)
for suffix, mode, want in [
    ("owned-output", "", 0),
    ("owned-output-mutant-authority", "ignore-authority", 1),
    ("owned-output-mutant-copy", "ignore-copy-currentness", 1),
]:
    cmd = [p, "-NoProfile", "-File", "tools/test/test_updater_owned_output.ps1", "-Module", mod]
    if mode:
        cmd += ["-Inverse", mode]
    commands.append((suffix, cmd, want))
r = []
for name, cmd, want in commands:
    x = subprocess.run(cmd, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (b / "logs" / (name + ".txt")).write_text(x.stdout)
    row = {
        "name": name,
        "command": cmd,
        "expected_exit": want,
        "exit_code": x.returncode,
        "expected_outcome": x.returncode == want,
    }
    r.append(row)
    print(json.dumps(row), flush=True)
(b / "logs/gates-receipt.json").write_text(json.dumps(r, indent=2) + "\n")
assert all(x["expected_outcome"] for x in r)
