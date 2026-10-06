"""Reap actual orphaned process-group fixtures without writing artifacts."""

import ctypes
import json
import os
import signal
import subprocess
import sys
import time


def reap_available(child, state):
    """Consume kernel wait receipts without treating signal delivery as exit."""
    while True:
        try:
            pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid == 0:
            return
        if pid == child.pid:
            state["main"] = os.waitstatus_to_exitcode(status)
            child.returncode = state["main"]
        else:
            state["adopted"].add(pid)


def retire_remaining(child, state):
    """Kill and physically reap only children adopted by this fixture wrapper."""
    deadline = time.monotonic() + 5
    leaked = False
    while True:
        reap_available(child, state)
        owned = []
        # The per-thread children file requires an optional kernel feature;
        # ordinary process stat receipts expose actual PPID on every host here.
        for entry in os.scandir("/proc"):
            if not entry.name.isdecimal():
                continue
            try:
                with open(f"/proc/{entry.name}/stat", "rb") as receipt:
                    fields = receipt.read().rsplit(b")", 1)[1].split()
            except FileNotFoundError:
                continue
            if int(fields[1]) == os.getpid():
                owned.append(int(entry.name))
        if not owned:
            reap_available(child, state)
            return leaked
        leaked = True
        for owned_pid in owned:
            try:
                os.kill(owned_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if time.monotonic() >= deadline:
            raise RuntimeError("native fixture cleanup remains physically pending")
        time.sleep(0.002)


def main(argv=None, deadline_seconds=40):
    """Run one native Lua probe and preserve teardown on failure and timeout."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER refused")
    command = sys.argv[1:] if argv is None else argv
    child = subprocess.Popen(command)
    deadline = time.monotonic() + deadline_seconds
    state = {"main": None, "adopted": set()}
    failure = None
    leaked = False
    try:
        while state["main"] is None:
            if time.monotonic() >= deadline:
                raise RuntimeError("native owned-process probe exceeded its deadline")
            reap_available(child, state)
            time.sleep(0.002)
    except BaseException as error:
        failure = error
    finally:
        try:
            leaked = retire_remaining(child, state)
        except BaseException as cleanup_error:
            if failure is None:
                failure = cleanup_error
            else:
                if hasattr(failure, "add_note"):
                    failure.add_note(str(cleanup_error))
    if failure is not None:
        raise failure
    if leaked:
        raise RuntimeError(
            "the native probe leaked children; independent teardown killed and physically reaped them"
        )
    print(f"Native subreaper: {len(state['adopted'])} adopted descendants physically reaped")
    # retire_remaining observed no owned children; the refusal paths above
    # prohibit this receipt after rescue or unknown physical retirement.
    print(
        "Native subreaper closure: "
        + json.dumps({"pending": 0, "rescue": 0, "adopted": len(state["adopted"])}, sort_keys=True)
    )
    return state["main"]


if __name__ == "__main__":
    sys.exit(main())
