# tools/diagnostics/macos_pty_process_group_native.py
"""Receive the actual PTY wrapper against exclusively owned inert Darwin children.

The first case keeps exit78 waitable with WNOWAIT before the wrapper's initial
zero-signal probe. The second keeps an authenticated descendant alive after its
leader exits, then exercises the wrapper's real TERM/KILL and bounded drain.
Permission refusals are covered separately by the canonical deterministic model.
"""

import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

from macos_owned_process import NativeProcessGroups, OwnedProcessGroup, ProcBSDInfo


def require(condition, message):
    """Refuse missing native facts without turning unsupported input into a pass."""
    if not condition:
        raise RuntimeError(message)


def exclusive_json(path, value):
    """Write metadata only to a fresh path inside the private receiving container."""
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def native_identity(native, pid):
    """Observe native identity without signalling or acquiring a foreign process."""
    info = ProcBSDInfo()
    ctypes.set_errno(0)
    count = native.library.proc_pidinfo(pid, 3, 1, ctypes.byref(info), ctypes.sizeof(info))
    if count == 0 and ctypes.get_errno() == errno.ESRCH:
        return None
    require(count == ctypes.sizeof(info) and info.pid == pid, "Native child identity unavailable")
    return {
        "pid": int(info.pid),
        "ppid": int(info.ppid),
        "pgid": int(info.pgid),
        "start_sec": int(info.start_sec),
        "start_usec": int(info.start_usec),
        "status": int(info.status),
    }


def same_birth(left, right):
    """Compare a retained native birth identity; PID alone never authorizes cleanup."""
    return right is not None and all(
        left[key] == right[key] for key in ("pid", "start_sec", "start_usec")
    )


def wait_until(predicate, timeout, message):
    """Bound source observation without polling or reaping the protected group leader."""
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        require(time.monotonic() < deadline, message)
        time.sleep(0.01)


DESCENDANT = r"""import json, os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
ready = pathlib.Path(sys.argv[1])
with ready.open("x") as stream:
    json.dump({"pid": os.getpid(), "ppid": os.getppid(), "pgid": os.getpgrp()}, stream)
# A bounded natural exit remains available even if the wrapper itself refuses.
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    time.sleep(0.02)
"""

LEADER = r"""import os, pathlib, subprocess, sys, time
ready, permit = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
descendant = subprocess.Popen([sys.executable, "-B", "-c", sys.argv[3], str(ready)])
deadline = time.monotonic() + 5
while not permit.exists():
    if time.monotonic() >= deadline:
        sys.exit(79)
    time.sleep(0.01)
sys.exit(78)
"""


def receive(wrapper, mode, container, native):
    """Run the unmodified wrapper with transparent native acquisition observers."""
    events = []
    acquired = []
    owned_descriptors = set()
    namespace = {}
    descendant_birth = None
    actual_popen, actual_killpg = subprocess.Popen, os.killpg
    actual_openpty, actual_close = os.openpty, os.close
    old_handlers = {
        sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    old_argv = sys.argv
    failure = None
    result = None
    started = time.monotonic()

    class TrackedProcess:
        """Keep the actual Popen while observing the wrapper's exact poll/wait order."""

        def __init__(self, process):
            self.process = process
            self.pid = process.pid

        @property
        def returncode(self):
            return self.process.returncode

        def poll(self):
            value = self.process.poll()
            events.append({"kind": "poll", "pid": self.pid, "result": value})
            return value

        def wait(self):
            value = self.process.wait(timeout=2)
            events.append({"kind": "wait", "pid": self.pid, "result": value})
            return value

    def observe_spawn(arguments, **options):
        nonlocal descendant_birth
        process = actual_popen(arguments, **options)
        group = OwnedProcessGroup(process, native)
        acquired.append(group)  # Register before any observer can refuse.
        require(
            os.getpgid(process.pid) == process.pid, "Child did not acquire its own native group"
        )
        events.append({"kind": "spawn", "pid": process.pid, "group_id": process.pid})
        if mode == "descendant":
            ready = container / "descendant-ready.json"
            wait_until(ready.exists, 3, "Owned descendant did not acknowledge readiness")
            packet = json.loads(ready.read_text(encoding="utf-8"))
            descendant_birth = native_identity(native, packet["pid"])
            require(
                descendant_birth is not None
                and descendant_birth["ppid"] == process.pid
                and descendant_birth["pgid"] == process.pid
                and packet["ppid"] == process.pid
                and packet["pgid"] == process.pid,
                "Descendant was not the acquired leader's native child",
            )
            (container / "leader-exit-permit").touch(exist_ok=False)
        group.wait_for_exit(3)
        observation = group.observe_exit()
        require(
            observation.si_code == os.CLD_EXITED and observation.si_status == 78,
            "Synthetic leader did not retain its exact exit78 reservation",
        )
        events.append(
            {
                "kind": "waitable_exit",
                "pid": process.pid,
                "status": 78,
                "reaped": process.returncode is not None,
            }
        )
        if mode == "descendant":
            members = native.live_members(process.pid, process.pid)
            require(
                descendant_birth["pid"] in members,
                "Owned descendant not live at the leader boundary",
            )
            # Deliver the wrapper's registered signal callback during acquisition,
            # when proc is still None. Real child-group signals happen below.
            namespace["forward_signal"](signal.SIGTERM, None)
        return TrackedProcess(process)

    def observe_signal(group_id, signum):
        require(
            len(acquired) == 1 and group_id == acquired[0].process.pid,
            "Wrapper attempted to signal an unowned group",
        )
        if signum != 0:
            require(
                descendant_birth is not None, "A zombie-only case cannot authorize a real signal"
            )
            live = native_identity(native, descendant_birth["pid"])
            require(
                same_birth(descendant_birth, live) and live["pgid"] == group_id,
                "The acquired descendant no longer owns this native group",
            )
        try:
            result = actual_killpg(group_id, signum)
        except OSError as error:
            events.append(
                {"kind": "signal", "group_id": group_id, "signal": signum, "errno": error.errno}
            )
            raise
        events.append({"kind": "signal", "group_id": group_id, "signal": signum, "errno": 0})
        return result

    def observe_openpty():
        pair = actual_openpty()
        owned_descriptors.update(pair)
        return pair

    def observe_close(descriptor):
        result = actual_close(descriptor)
        owned_descriptors.discard(descriptor)
        return result

    try:
        subprocess.Popen, os.killpg = observe_spawn, observe_signal
        os.openpty, os.close = observe_openpty, observe_close
        child = [sys.executable, "-B", "-c", "import sys;sys.exit(78)"]
        if mode == "descendant":
            child = [
                sys.executable,
                "-B",
                "-c",
                LEADER,
                str(container / "descendant-ready.json"),
                str(container / "leader-exit-permit"),
                DESCENDANT,
            ]
        sys.argv = ["owned-pty-wrapper", *child]
        try:
            exec(compile(wrapper, "actual-pty-wrapper", "exec"), namespace)
        except SystemExit as terminal:
            result = terminal.code
        except BaseException as error:
            failure = {"type": type(error).__name__, "message": str(error)}
    finally:
        subprocess.Popen, os.killpg = actual_popen, actual_killpg
        os.openpty, os.close, sys.argv = actual_openpty, actual_close, old_argv
        for sig, previous in old_handlers.items():
            signal.signal(sig, previous)
        for group in acquired:
            if group.process.returncode is None:
                require(
                    group.settle(timeout=1),
                    "Exact reserved native group cleanup remained uncertain",
                )
        if descendant_birth is not None:
            wait_until(
                lambda: (
                    not same_birth(
                        descendant_birth, native_identity(native, descendant_birth["pid"])
                    )
                ),
                10,
                "Owned descendant did not retire; no terminal receipt can be published",
            )
        for descriptor in tuple(owned_descriptors):
            actual_close(descriptor)
            owned_descriptors.remove(descriptor)

    exclusive_json(
        container / "observations.json",
        {
            "mode": mode,
            "wrapper_exit": result,
            "exception": failure,
            "descendant_birth": descendant_birth,
            "events": events,
            "owned_descriptors_remaining": sorted(owned_descriptors),
            "leader_exit": acquired[0].process.returncode if acquired else None,
        },
    )
    require(
        len(acquired) == 1 and acquired[0].process.returncode == 78,
        "Actual child exit78 was not preserved after native retirement",
    )
    probes = [event for event in events if event["kind"] == "signal" and event["signal"] == 0]
    signals = [
        event["signal"] for event in events if event["kind"] == "signal" and event["signal"] != 0
    ]
    waits = [event for event in events if event["kind"] == "waitable_exit"]
    require(waits[0]["reaped"] is False, "The control did not reach a genuine unreaped leader")
    if mode == "zombie":
        require(
            probes[0]["errno"] == errno.EPERM,
            "This Darwin host did not reproduce zombie-only EPERM; proof remains unqualified",
        )
        require(
            any(event["errno"] == errno.ESRCH for event in probes[1:]),
            "Exact leader reaping did not produce the independent group disappearance observation",
        )
        require(signals == [], "A zombie-only group required no real signal")
    else:
        require(
            signals == [signal.SIGTERM, signal.SIGKILL],
            "The real owned TERM-resistant descendant did not receive TERM then KILL exactly",
        )
        require(
            time.monotonic() - started < 7,
            "Wrapper did not achieve bounded native descendant retirement",
        )
    require(
        failure is None and result == 78, "Wrapper replaced the actual child exit: " + repr(failure)
    )
    return {
        "mode": mode,
        "wrapper_exit": result,
        "child_exit": 78,
        "elapsed_ms": (time.monotonic() - started) * 1000,
        "descendant_birth": descendant_birth,
        "events": events,
        "resources_retired": True,
    }


def main():
    """Refuse unsupported hosts and publish two complete native receiving rows."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    options = parser.parse_args()
    require(
        sys.platform == "darwin", "This receiving tier requires Darwin; no skip or model success"
    )
    require(
        options.output_dir.is_dir() and not options.output_dir.is_symlink(),
        "Owned evidence root missing",
    )
    native = NativeProcessGroups()
    source = options.source.read_bytes()
    match = re.search(
        r"local WRAPPER_SOURCE = \[\[([\s\S]*?)\n\]\]\n\n--- Removes", source.decode()
    )
    require(match is not None, "Actual canonical wrapper block is missing")
    container = Path(tempfile.mkdtemp(prefix="pty-native-", dir=options.output_dir))
    os.chmod(container, 0o700)
    rows = []
    failure = None
    for mode in ("zombie", "descendant"):
        trial = container / mode
        trial.mkdir(mode=0o700)
        try:
            row = receive(match[1], mode, trial, native)
            rows.append({"state": "passed", **row})
        except Exception as error:
            failure = failure or str(error)
            rows.append({"state": "failed", "mode": mode, "error": str(error)})
    receipt = {
        "source_sha256": hashlib.sha256(source).hexdigest(),
        "python": sys.version,
        "platform": sys.platform,
        "rows": rows,
        "native_cases": 2,
        "permission_tier": "separate canonical recording model",
        "native_permission_failure_claimed": False,
    }
    exclusive_json(container / "receipt.json", receipt)
    print(json.dumps(receipt, indent=2))
    require(
        failure is None and len(rows) == 2 and all(row["state"] == "passed" for row in rows),
        "Native PTY receiving refused: " + str(failure),
    )


if __name__ == "__main__":
    main()
