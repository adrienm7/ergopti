#!/usr/bin/env python3
# tests/hardware/run_manager_input_owner_real.py

"""Check a saved-pair Manager through the actual daemon and owned kernel devices.

Virtual source classification is explicitly controlled. No physical keyboard,
picker capability, or legacy input-owner assertion is qualified by this probe.
Each native scenario retains the existing family's exact forty-second budget.
"""

import argparse
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys

from native_fixture_family import run as run_family


SCENARIOS = (
    "manager-saved-pair-shift-repeat-up",
    "manager-omit-other-original-source",
    "manager-replace-frame-original-source",
    "manager-replace-other-original-source",
)
CHECKS = (13, 14, 14, 14)
LUA_PATH = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;"
HARDWARE = Path(__file__).resolve().parent
DRIVER = HARDWARE.parent.parent


def prerequisites():
    """Refuse missing kernel authority before allocating a scenario family."""
    if not Path("/dev/input").is_dir() or not os.access("/dev/uinput", os.R_OK | os.W_OK):
        raise RuntimeError("real writable /dev/uinput and /dev/input are mandatory")
    census = Path(f"/proc/self/task/{os.getpid()}/children")
    census.read_text(encoding="ascii")
    runtime = shutil.which(os.environ.get("ERGOPTI_MANAGER_TEST_LUA", "luajit"))
    xvfb = shutil.which("Xvfb")
    if runtime is None or xvfb is None:
        raise RuntimeError("native LuaJIT and Xvfb are mandatory")
    probe = subprocess.run(
        [runtime, "-e", 'assert(jit and require("ffi") and require("luv"))'],
        check=False,
        timeout=3,
        capture_output=True,
        text=True,
    )
    if probe.returncode != 0:
        raise RuntimeError("native LuaJIT FFI and luv admission failed")
    return runtime, xvfb


def scenario_process(name):
    """Own one X server and one genuine Lua daemon beneath the unchanged family."""
    runtime, xvfb_program = prerequisites()
    family_root = Path(os.environ["TMPDIR"]).resolve(strict=True)
    home = family_root / "manager-home"
    home.mkdir(mode=0o700)
    reader, writer = os.pipe()
    server = None
    try:
        server = subprocess.Popen(
            [
                xvfb_program,
                "-displayfd",
                str(writer),
                "-screen",
                "0",
                "1024x768x24",
                "-nolisten",
                "tcp",
            ],
            pass_fds=(writer,),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        os.close(writer)
        writer = None
        if not select.select([reader], [], [], 5)[0]:
            raise RuntimeError("owned Xvfb did not publish its display within five seconds")
        display = os.read(reader, 32).decode("ascii").strip()
        if not display.isdecimal() or server.poll() is not None:
            raise RuntimeError("owned Xvfb publication is invalid")
        env = dict(
            os.environ,
            HOME=str(home),
            XDG_CONFIG_HOME=str(home / ".config"),
            XDG_DATA_HOME=str(home / ".local/share"),
            XDG_STATE_HOME=str(home / ".local/state"),
            DISPLAY=f":{display}",
            LUA_PATH=LUA_PATH,
        )
        # The native family owns the deadline and physical retirement even when
        # a Lua failure prevents ordinary shutdown. Do not kill its supervisor.
        child = subprocess.Popen(
            [runtime, str(HARDWARE / "run_manager_input_owner_real.lua"), name],
            cwd=DRIVER,
            env=env,
            close_fds=True,
        )
        result = child.wait()
        print(f"MANAGER_NATIVE_CHILD_EXIT {name} {result}", flush=True)
        return result
    finally:
        os.close(reader)
        if writer is not None:
            os.close(writer)
        if server is not None:
            if server.poll() is None:
                server.terminate()
            try:
                server.wait(timeout=2)
            except subprocess.TimeoutExpired as error:
                # Retain the exact live owner for Family's real pidfd teardown.
                raise RuntimeError("owned Xvfb retirement remains pending") from error
            print("MANAGER_NATIVE_XVFB_REAPED", flush=True)


def verify_scenario(result, name, expected_count, oracle):
    """Compare literal kernel reports and exact execution counts independently."""
    if result.returncode != 0:
        raise RuntimeError(f"{name}: native scenario refused with status {result.returncode}")
    pattern = rf"^MANAGER_INPUT_OWNER_SCENARIO {re.escape(name)} (\d+) (\d+) (\d+)$"
    summaries = re.findall(pattern, result.stdout, flags=re.MULTILINE)
    if summaries != [(str(expected_count), "0", "1")]:
        raise RuntimeError(f"{name}: missing or incorrect native scenario count")
    wire = {}
    for line in result.stdout.splitlines():
        if line.startswith("MANAGER_NATIVE_WIRE "):
            frame = json.loads(line.removeprefix("MANAGER_NATIVE_WIRE "))
            if set(frame) != {"scenario", "segment", "rows"} or frame["scenario"] != name:
                raise RuntimeError(f"{name}: invalid wire observation envelope")
            segment = frame["segment"]
            if segment in wire:
                raise RuntimeError(f"{name}: duplicate wire observation")
            rows = frame["rows"]
            if not isinstance(rows, list) or any(
                not isinstance(row, list) or len(row) != 3 or any(type(v) is not int for v in row)
                for row in rows
            ):
                raise RuntimeError(f"{name}: malformed native wire rows")
            wire[segment] = rows
    expected = {"pair": oracle["pair_prefix_rows"], "character": oracle["case"]["character_rows"]}
    if "following_rows" in oracle["case"]:
        expected["following"] = oracle["case"]["following_rows"]
    if wire != expected:
        raise RuntimeError(
            f"{name}: observed kernel KEY/SYN reports differ from the literal oracle"
        )
    if result.stdout.splitlines().count(f"MANAGER_NATIVE_CHILD_EXIT {name} 0") != 1:
        raise RuntimeError(f"{name}: missing exact daemon wait receipt")
    if result.stdout.splitlines().count("MANAGER_NATIVE_XVFB_REAPED") != 1:
        raise RuntimeError(f"{name}: missing exact Xvfb wait receipt")
    return expected_count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=SCENARIOS)
    args = parser.parse_args()
    if args.scenario:
        return scenario_process(args.scenario)
    try:
        prerequisites()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(
            f"ENVIRONMENT: native saved-pair Manager prerequisite refused: {error}", file=sys.stderr
        )
        return 2
    corpus = json.loads((HARDWARE / "manager_input_owner_oracles.json").read_text(encoding="utf-8"))
    if tuple(row["id"] for row in corpus["cases"]) != SCENARIOS or corpus["scenario_count"] != 4:
        raise RuntimeError("independent finite Manager scenario corpus changed")
    checks, completed = 0, []
    for index, name in enumerate(SCENARIOS):
        result = run_family(
            [sys.executable, str(Path(__file__).resolve()), "--scenario", name],
            timeout=40,
            cwd=DRIVER,
        )
        if result.stdout:
            print(result.stdout, end="", flush=True)
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr, flush=True)
        checks += verify_scenario(
            result,
            name,
            CHECKS[index],
            {"pair_prefix_rows": corpus["pair_prefix_rows"], "case": corpus["cases"][index]},
        )
        completed.append(name)
    if tuple(completed) != SCENARIOS or checks != 55:
        raise RuntimeError(
            "the exact four Manager scenarios and fifty-five Lua checks did not complete"
        )
    print("MANAGER_INPUT_OWNER_KERNEL 55 0 4")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, AssertionError, subprocess.SubprocessError, ValueError) as error:
        print(f"FAIL native saved-pair Manager: {error}", file=sys.stderr)
        raise SystemExit(1)
