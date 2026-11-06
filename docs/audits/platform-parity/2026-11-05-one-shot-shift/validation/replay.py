"""Replay frozen programs into external logs; never rewrite role submissions."""

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
CAMPAIGN = HERE.parent
ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else HERE.parents[4]
OUT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else HERE / "root-replay"
OUT.mkdir(parents=True, exist_ok=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(value):
    if isinstance(value, list):
        return [normalized(x) for x in value]
    if isinstance(value, dict):
        return {k: normalized(v) for k, v in value.items()}
    if isinstance(value, str):
        value = re.sub(r"^.*(?=/static/ergopti_plus/)", "<checkout>", value)
        return re.sub(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d{3} ", "<timestamp> ", value)
    return value


def equivalent(actual, expected):
    for prefix in ("", "PUBLIC_PROBE=", "CHANNEL_PROBE="):
        try:
            a = actual.split("=", 1)[1] if prefix else actual
            e = expected.split("=", 1)[1] if prefix else expected
            if normalized(json.loads(a)) == normalized(json.loads(e)):
                return (
                    "Parsed JSON equal; only logger timestamp and error checkout prefix normalized"
                )
        except (ValueError, IndexError):
            pass
    assert actual == expected, "Replay differs from frozen observation"
    return "Exact text equal"


frozen_before = {
    str(p.relative_to(CAMPAIGN)): digest(p)
    for role in ("macos", "windows", "linux", "shared")
    for p in (CAMPAIGN / role).rglob("*")
    if p.is_file()
}

plans = []
mods = [
    "tests.unit.modules.keymap.synthetic.test_one_shot_shift",
    "tests.unit.adapters.synthetic_input.test_one_shot_shift",
    "tests.unit.modules.keymap.lifecycle.test_start_commit_transaction",
    "tests.unit.platform.remap.config.test_one_shot_timeout_is_shared",
    "tests.unit.modules.gestures.actions.test_sticky_modifiers",
    "tests.unit.modules.shortcuts.pause_owners.test_sticky_modifiers",
]
mac_jobs = [("public", "public-probe.lua", []), ("config", "config-probe.lua", [])]
mac_jobs += [(f"registered-{i}", "run-module.lua", [mod]) for i, mod in enumerate(mods, 1)]
for name, program, args in mac_jobs:
    plans.append(
        (
            "macos-" + name,
            ["lua", str(CAMPAIGN / "macos" / program), str(ROOT), *args],
            CAMPAIGN / "macos" / f"sweep-1-{name}.log",
        )
    )
plans.append(
    (
        "windows-source",
        ["python3", str(CAMPAIGN / "windows/source-contract.py"), str(ROOT)],
        CAMPAIGN / "windows/source-contract.json",
    )
)
for row in json.loads((CAMPAIGN / "linux/final-dry-1/results.json").read_text()):
    if row["name"] == "source-contract":
        continue  # Frozen checker asserts HEAD: historical claim, not descendant checker.
    old = row["command"]
    plans.append(
        (
            "linux-" + row["name"],
            [old[0], str(CAMPAIGN / "linux" / Path(old[1]).name), str(ROOT), *old[3:]],
            CAMPAIGN / "linux" / row["log"],
        )
    )
for row in json.loads((CAMPAIGN / "shared/dry-receipts.json").read_text())["sweeps"][0][
    "processes"
]:
    old = row["command"]
    program = (
        ROOT / "tools/test/test-tap-hold-one-shot-results-single-source.cjs"
        if row["name"] == "single-source"
        else CAMPAIGN / "shared" / Path(old[1]).name
    )
    args = [] if row["name"] == "single-source" else [str(ROOT), *old[3:]]
    plans.append(
        (
            "shared-" + row["name"],
            [old[0], str(program), *args],
            CAMPAIGN / "shared" / row["stdout"],
        )
    )
plans += [
    ("metadata-controls", [sys.executable, str(CAMPAIGN / "check_project.py"), str(ROOT)], None),
    ("native-inverse", ["luajit", str(HERE / "native-inverse.lua"), str(ROOT)], None),
    ("infinity-qualification", ["lua", str(HERE / "infinity-qualification.lua"), str(ROOT)], None),
]
checker = CAMPAIGN / "check_sources.py"
if checker.exists():
    plans.append(
        (
            "aggregate-source",
            [
                sys.executable,
                str(checker),
                str(ROOT),
                "--directory",
                str(CAMPAIGN),
                "--output",
                str(OUT / "source-check.json"),
            ],
            None,
        )
    )


def run(plan):
    name, command, baseline = plan
    with tempfile.TemporaryDirectory(prefix="oneshot-root-replay-") as private:
        env = dict(os.environ, TMPDIR=private, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
        toolchain = os.environ.get(
            "PARITY_TOOLCHAIN_BIN", "/workspace/scratch/parity-toolchain/ci-bin"
        )
        env["PATH"] = toolchain + os.pathsep + env["PATH"]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=240)
    stdout = OUT / (name + ".stdout.txt")
    stderr = OUT / (name + ".stderr.txt")
    stdout.write_bytes(result.stdout)
    stderr.write_bytes(result.stderr)
    receipt = {
        "name": name,
        "command": command,
        "program_sha256": digest(Path(command[1])),
        "exit_code": result.returncode,
        "stdout": stdout.name,
        "stderr": stderr.name,
        "stdout_sha256": digest(stdout),
        "stderr_sha256": digest(stderr),
        "private_TMPDIR": True,
    }
    if name == "macos-public" and result.returncode == 0:
        rows = {r["name"]: r for r in json.loads(result.stdout)}
        for code in (51, 36, 48, 53):
            assert rows[f"control-{code}"]["next_character"] == "a"
        for code in (123, 122):
            assert rows[f"control-{code}"]["next_character"] == "A"
        receipt["independent_controls"] = (
            "Editing controls51/36/48/53 spend; navigation/function123/122 preserve"
        )
    if name == "macos-config" and result.returncode == 0:
        rows = {r["input"]: r for r in json.loads(result.stdout)}
        assert rows[0]["accepted"] is False and rows[0]["save_calls"] == 0
        for value in (0.1, 0.9):
            assert (
                rows[value]["accepted"] is True
                and rows[value]["after"] == 0
                and rows[value]["saved"] == 0
            )
        for value, expected in ((1, 1), (2.5, 2), (2000, 2000)):
            assert rows[value]["after"] == expected and rows[value]["saved"] == expected
        receipt["independent_controls"] = (
            "Zero refused;0.1/0.9 accepted and stored0;1/2.5/2000 stored1/2/2000"
        )
    if result.returncode:
        receipt["error"] = "Replay process failed; inspect retained stderr/stdout"
    elif baseline:
        try:
            receipt["comparison"] = equivalent(result.stdout.decode(), baseline.read_text())
            receipt["baseline"] = str(baseline.relative_to(CAMPAIGN))
            receipt["baseline_sha256"] = digest(baseline)
        except AssertionError as error:
            receipt["error"] = str(error)
    return receipt


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    receipts = list(pool.map(run, plans))
frozen_after = {
    str(p.relative_to(CAMPAIGN)): digest(p)
    for role in ("macos", "windows", "linux", "shared")
    for p in (CAMPAIGN / role).rglob("*")
    if p.is_file()
}
assert frozen_before == frozen_after, "Frozen role artifacts changed during replay"
runtime_evidence = []
for name in ("lua", "luajit"):
    wrapper = Path(
        shutil.which(
            name,
            path=os.environ.get(
                "PARITY_TOOLCHAIN_BIN", "/workspace/scratch/parity-toolchain/ci-bin"
            )
            + os.pathsep
            + os.environ["PATH"],
        )
    )
    binary = wrapper.resolve()
    if binary.read_bytes()[:4] != b"\x7fELF":
        match = re.search(r"^exec (/[^ ]+)", wrapper.read_text(), re.M)
        assert match, "Unknown runtime wrapper"
        binary = Path(match[1]).resolve()
    assert binary.read_bytes()[:4] == b"\x7fELF"
    runtime_evidence.append(
        {
            "runtime": name,
            "wrapper": str(wrapper),
            "wrapper_sha256": digest(wrapper),
            "ELF_realpath": str(binary),
            "ELF_sha256": digest(binary),
        }
    )
summary = {
    "runtime_evidence": runtime_evidence,
    "runner_sha256": digest(Path(__file__)),
    "frozen_role_artifacts_unchanged": True,
    "frozen_role_artifact_count": len(frozen_before),
    "audited_sha": "9c565c88c9a1366a2e9b18c1b9d2868509510975",
    "repository_head": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip(),
    "qualification": "Independent frozen-owner replay; recorded ports are not native receiving. Native inverse uses real libxkbcommon with explicit US keymap, without physical capture, desktop authority or receiving application. Positive infinity boundary is programmatic, not a certified UI choice.",
    "linux_frozen_HEAD_checker": "Historical-only; not executed against descendant. Aggregate named-source checker authenticates current unchanged production bytes when present.",
    "aggregate_source_checker_present": checker.exists(),
    "processes": receipts,
    "failed": sum(bool(x.get("error")) for x in receipts),
}
(OUT / "receipts.json").write_text(json.dumps(summary, indent="\t") + "\n")
print(json.dumps({"processes": len(receipts), "failed": summary["failed"]}))
raise SystemExit(bool(summary["failed"]))
