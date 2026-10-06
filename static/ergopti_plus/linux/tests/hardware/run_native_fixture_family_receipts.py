#!/usr/bin/env python3
# tests/hardware/run_native_fixture_family_receipts.py

"""Force real ProgramRunner families to hang, then independently observe retirement."""

import ctypes
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import patch

import native_fixture_family as policy

from native_fixture_family import Family


DRIVER = Path(__file__).resolve().parents[2]
SUPERVISOR = Path(__file__).with_name("native_fixture_family.py")
WRAPPER = DRIVER.parents[2] / "tools/test/run-linux-window-switch-receipts.cjs"


def policy_controls():
    """Controlled no-process ports prove refusal retention, not native execution."""
    modes = [
        "term",
        "kill",
        "census",
        "acquire",
        "reap",
        "malformed_reap",
        "close",
        "namespace_stat",
        "namespace_remove",
    ]
    for mode in modes:
        state = dict(present=True, exited=False, consumed=False, removed=False, now=1.0)
        family = object.__new__(Family)
        family.child = None
        family.pidfds = {} if mode == "acquire" else {101: 41}
        family.reaped, family.closed = set(), 0
        family.base_identity = (7, 8)
        family.debt, family.grace_deadline = None, 0
        family.namespace_absent, family.settled = False, False
        family.namespace_removal_admitted = False
        namespace = SimpleNamespace()

        def refuse(operation):
            if mode == operation and not state["consumed"]:
                state["consumed"] = True
                raise PermissionError(1, "controlled native refusal")

        def census():
            refuse("census")
            return [101] if state["present"] else []

        def acquire(_pid):
            refuse("acquire")
            return 41

        def send(_descriptor, kind):
            refuse("term" if kind == signal.SIGTERM else "kill")
            if kind == signal.SIGKILL:
                state["exited"] = True

        def reap(_pid, _flags):
            refuse("reap")
            if mode == "malformed_reap" and not state["consumed"]:
                state["consumed"] = True
                return 0, 0
            state["present"] = False
            return 101, 0

        def close(_descriptor):
            refuse("close")

        def stat():
            refuse("namespace_stat")
            if state["removed"]:
                raise FileNotFoundError(2, "exact controlled namespace absence")
            return SimpleNamespace(st_dev=7, st_ino=8)

        def remove(_namespace):
            refuse("namespace_remove")
            state["removed"] = True

        namespace.lstat, namespace.exists = stat, lambda: not state["removed"]
        family.base, family.children = namespace, census
        if mode == "term":
            family.grace_deadline = None

            def poll():
                assert state["exited"]
                state["present"] = False
                return -15

            family.child = SimpleNamespace(pid=101, poll=poll)
        with (
            patch.object(policy.os, "pidfd_open", acquire),
            patch.object(policy.os, "waitpid", reap),
            patch.object(policy.os, "close", close),
            patch.object(policy.signal, "pidfd_send_signal", send),
            patch.object(
                policy.select,
                "select",
                lambda readers, *_args: (readers if state["exited"] else [], [], []),
            ),
            patch.object(policy.shutil, "rmtree", remove),
            patch.object(policy.time, "monotonic", lambda: state["now"]),
        ):
            assert family.retirement_step() is False, (
                f"{mode}: native refusal escaped or falsely settled"
            )
            assert family.debt and not family.settled and not family.namespace_absent
            assert not state["removed"], f"{mode}: refused ownership removed namespace"
            if mode in ["term", "kill", "census", "reap", "malformed_reap", "close"]:
                assert family.pidfds[101] == 41, (
                    f"{mode}: exact capability released before physical receipt"
                )
            if mode == "acquire":
                assert family.pidfds == {} and state["present"], (
                    "unreaped child acquisition authority was lost"
                )
            for _ in range(4):
                state["now"] += 1
                if family.retirement_step():
                    break
            assert family.settled and family.namespace_absent
            assert family.closed == len(family.reaped) == len(family.pidfds) == 1
            assert family.pidfds[101] is None and state["removed"] and not state["present"]
    print(
        f"Fixture refusal policy receipts: {len(modes)} controlled cases passed; no native processes created",
        flush=True,
    )


def verify_external_recovery(root, lua, fork, launcher):
    """Lose a real helper, keep its red result, and retire only the owned case."""
    case = root / "external-helper-loss"
    case.mkdir()
    owner = Family([], 1, None, "external-loss-owner")
    process, observed, helper_fd = None, [], None
    try:
        owner.base = Path(tempfile.mkdtemp(prefix="owned-", dir=case))
        owner.base.chmod(0o700)
        stat = owner.base.lstat()
        owner.base_identity = stat.st_dev, stat.st_ino
        args = [str(launcher), str(lua), sys.executable, str(fork), str(case)]
        receipt = case / "helper"
        source = case / "wrapper.cjs"
        source.write_text(
            "const {run}=require(" + json.dumps(str(WRAPPER)) + ");"
            "const {spawn}=require('node:child_process');const fs=require('node:fs');"
            "run({fixtures:[{args:" + json.dumps(args) + ",timeout:5}],"
            "spawnChild:(c,a,o)=>{const child=spawn(c,a,o);fs.writeFileSync("
            + json.dumps(str(receipt))
            + ",String(child.pid));return child;}})"
            ".then(s=>{process.exitCode=s});\n"
        )
        process = subprocess.Popen(
            ["node", str(source)],
            cwd=DRIVER,
            env=dict(os.environ, TMPDIR=str(owner.base)),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        owner.child = process
        owner.acquire(process.pid)
        deadline = time.monotonic() + 3
        while not all((case / name).exists() for name in ["helper", "leader", "1", "2"]):
            assert process.poll() is None and time.monotonic() < deadline
            time.sleep(0.005)
        pids = [int((case / "leader").read_text())]
        for number in ["1", "2"]:
            pids.extend(int(value) for value in (case / number).read_text().split())
        assert len(set(pids)) == 5
        for pid in pids:
            observed.append((pid, os.pidfd_open(pid)))
            assert not select.select([observed[-1][1]], [], [], 0)[0]
        helper = int(receipt.read_text())

        # The recorded PID is only an observation. Authority comes from the
        # exact live root pidfd and its kernel direct-child census on both sides
        # of acquiring the helper pidfd, never argv or a global process scan.
        def root_children():
            assert not owner.exited(process.pid)
            return [
                int(pid)
                for pid in Path(f"/proc/{process.pid}/task/{process.pid}/children")
                .read_text()
                .split()
            ]

        assert helper in root_children()
        helper_fd = os.pidfd_open(helper)
        assert helper in root_children() and not select.select([helper_fd], [], [], 0)[0]
        assert signal.pidfd_send_signal(helper_fd, signal.SIGKILL) is None
        # A detached Lua leader may still hold the wrapper output pipes after
        # the helper dies. Root exit is a separate physical observation: drain
        # output only after this external owner retires the adopted family.
        process.wait(timeout=15)
        assert process.returncode == 1, "lost helper must remain a red native result"
        assert owner.exited(process.pid), "exact wrapper root pidfd remained live"
        assert owner.retire() is True and owner.settled and owner.namespace_absent
        stdout, stderr = process.communicate(timeout=15)
        assert "[BLOCKED] Native supervisor authority lost" in stderr
        assert process.stdout.closed and process.stderr.closed
        for pid, descriptor in observed:
            assert select.select([descriptor], [], [], 0)[0]
            assert not Path(f"/proc/{pid}").exists(), "exact adopted descendant remained unreaped"
        assert select.select([helper_fd], [], [], 0)[0]
        assert not Path(f"/proc/{helper}").exists()
        assert owner.closed == len(owner.pidfds) == len(owner.reaped)
        print("Native external recovery receipts: 1 passed, 0 failed, 0 skipped", flush=True)
    finally:
        assert owner.retire() is True and owner.settled and owner.namespace_absent
        if process is not None:
            process.wait()
            for stream in [process.stdout, process.stderr]:
                if stream is not None and not stream.closed:
                    stream.close()
        for _, descriptor in observed:
            os.close(descriptor)
        if helper_fd is not None:
            os.close(helper_fd)


def main():
    policy_controls()
    if "--policy-only" in sys.argv:
        return
    Family([], 1, None, "observer-prerequisite")
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0, (
        "native observer requires exact orphan ownership"
    )
    selected = SUPERVISOR
    if "--causal-supervisor" in sys.argv:
        selected = Path(sys.argv[sys.argv.index("--causal-supervisor") + 1]).resolve()
    with tempfile.TemporaryDirectory(prefix="ergopti-native-family-control-") as folder:
        root = Path(folder)
        fork = root / "fork.py"
        fork.write_text("""import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = os.fork()
if child == 0:
    os.setsid()
    with open(sys.argv[1] + ".child", "w") as output:
        output.write(str(os.getpid()))
    while True: time.sleep(1)
while not os.path.exists(sys.argv[1] + ".child"): time.sleep(0.001)
with open(sys.argv[1], "w") as output:
    output.write(str(os.getpid()) + " " + open(sys.argv[1] + ".child").read())
while True: time.sleep(1)
""")
        lua = root / "hang.lua"
        lua.write_text("""local uv = require("luv")
local Runner = require("adapters.program_runner")
local handles = {}
for i = 1, 2 do
    local h = assert(Runner.spawn(arg[1], {arg[2], arg[3] .. "/" .. i}, function() end, function() return true end))
    assert(h.start()); handles[i] = h
end
local file = assert(io.open(arg[3] .. "/leader", "w")); file:write(uv.os_getpid()); file:close()
while true do uv.sleep(100) end
""")
        launcher = root / "launch.py"
        launcher.write_text("import os, sys\nos.execvp('luajit', ['luajit', *sys.argv[1:]])\n")
        checks = 0
        modes = ["deadline", "term", "interrupt", "wrapper_term", "wrapper_deadline"]
        for mode in modes:
            case = root / mode
            case.mkdir()
            reader, writer = os.pipe()
            process, original_fds = None, []
            owner = Family([], 1, None, "external-case-owner")
            frames = []
            try:
                # This independent subreaper retains the case root pidfd before
                # the wrapper can lose its own child authority. The private
                # TMPDIR gives this owner an exact namespace to retire as well.
                owner.base = Path(tempfile.mkdtemp(prefix="owned-", dir=case))
                owner.base.chmod(0o700)
                stat = owner.base.lstat()
                owner.base_identity = stat.st_dev, stat.st_ino
                case_env = dict(os.environ, TMPDIR=str(owner.base))
                args = [str(launcher), str(lua), sys.executable, str(fork), str(case)]
                if mode.startswith("wrapper_"):
                    wrapper_launch = case / "wrapper.cjs"
                    wrapper_launch.write_text(
                        "const {run}=require("
                        + json.dumps(str(WRAPPER))
                        + ");run({fixtures:[{args:"
                        + json.dumps(args)
                        + ",timeout:5}]}).then(s=>{process.exitCode=s});\n"
                    )
                    process = subprocess.Popen(
                        ["node", str(wrapper_launch)],
                        cwd=DRIVER,
                        env=case_env,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    os.close(writer)
                    writer = None
                else:
                    process = subprocess.Popen(
                        [
                            sys.executable,
                            str(selected),
                            "--timeout",
                            "5",
                            "--receipt-fd",
                            str(writer),
                            "--token",
                            mode,
                            "--",
                            sys.executable,
                            *args,
                        ],
                        cwd=DRIVER,
                        env=case_env,
                        pass_fds=(writer,),
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    os.close(writer)
                    writer = None
                owner.child = process
                owner.acquire(process.pid)
                ready = time.monotonic() + 3
                while not all((case / name).exists() for name in ["leader", "1", "2"]):
                    assert process.poll() is None, (
                        "fixture exited before actual independent-group readiness"
                    )
                    assert time.monotonic() < ready, (
                        "actual independent groups did not publish readiness"
                    )
                    time.sleep(0.005)
                pids = [int((case / "leader").read_text())]
                for number in ["1", "2"]:
                    pids.extend(int(value) for value in (case / number).read_text().split())
                assert len(set(pids)) == 5
                for pid in pids:
                    original_fds.append(os.pidfd_open(pid))
                    assert not select.select([original_fds[-1]], [], [], 0)[0], (
                        "missing positive live-process control"
                    )
                assert os.getpgid(pids[1]) == pids[1] and os.getpgid(pids[3]) == pids[3], (
                    "real ProgramRunner workers did not create independent groups"
                )
                assert os.getpgid(pids[2]) == pids[2] and os.getpgid(pids[4]) == pids[4], (
                    "native descendants did not escape leader groups"
                )
                if mode in ["term", "wrapper_term"]:
                    owner.send(process.pid, signal.SIGTERM)
                elif mode == "interrupt":
                    owner.send(process.pid, signal.SIGINT)
                stdout, stderr = process.communicate(timeout=15)
                assert process.stdout.closed and process.stderr.closed, (
                    "owned native output descriptors retained debt"
                )
                expected = (
                    130 if mode == "interrupt" else 143 if mode in ["term", "wrapper_term"] else 124
                )
                assert process.returncode == expected, (mode, process.returncode, stdout, stderr)
                for descriptor, pid in zip(original_fds, pids):
                    assert select.select([descriptor], [], [], 0)[0], (
                        "forced deadline falsely settled a live detached process"
                    )
                    assert not Path(f"/proc/{pid}").exists(), (
                        "original owned process was not reaped"
                    )
                if not mode.startswith("wrapper_"):
                    packet = os.read(reader, 4096)
                    assert os.read(reader, 1) == b"", "owned receipt descriptor did not close"
                    frames = [json.loads(line) for line in packet.splitlines()]
                    assert [row["stage"] for row in frames] == ["ready", "settled"]
                    terminal = frames[-1]
                    assert terminal["supervisor"] == process.pid and terminal["token"] == mode
                    assert terminal["status"] == expected
                    assert terminal["acquired"] == terminal["reaped"] == terminal["closed"] == 5
                    assert terminal["namespace_absent"] is True
                assert not stderr, (mode, stderr)
                checks += 1
                print(
                    f"PASS native fixture family {mode}: original pidfds exited, exact IDs reaped, kernel descriptors and namespace retired",
                    flush=True,
                )
            finally:
                # The observer became a subreaper before creating any helper.
                # A deliberately broken helper therefore leaves children only
                # in this exact observer scope, never at container PID 1.
                # Refused signal/census/reap/close or a replaced namespace
                # retains this exact owner. A red wrapper status stays red;
                # physical cleanup cannot change any original assertion.
                assert owner.retire() is True and owner.settled and owner.namespace_absent
                if process is not None:
                    process.wait()
                    for stream in [process.stdout, process.stderr]:
                        if stream is not None and not stream.closed:
                            stream.close()
                for descriptor in original_fds:
                    os.close(descriptor)
                os.close(reader)
                if writer is not None:
                    os.close(writer)
        print(f"Native fixture family receipts: {checks} passed, 0 failed, 0 skipped")
        verify_external_recovery(root, lua, fork, launcher)


if __name__ == "__main__":
    main()
