#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/application_operand_diagnostics.py
"""Capture one acquired GTK launch, without changing application admission."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


CAPTURE_LIMIT = 4096


def publish(path, packet):
    """Publish one complete diagnostic through an exclusive owned stage."""
    path = Path(path)
    stage = path.with_name(path.name + ".stage")
    if path.exists():
        raise FileExistsError("Diagnostic destination already exists")
    with stage.open("xb") as stream:
        stream.write((json.dumps(packet, sort_keys=True) + "\n").encode())
        stream.flush()
        os.fsync(stream.fileno())
    os.link(stage, path)
    stage.unlink()


def capture(path):
    """Export bounded bytes explicitly as a prefix, never a fabricated full digest."""
    with Path(path).open("rb") as stream:
        total = os.fstat(stream.fileno()).st_size
        data = stream.read(CAPTURE_LIMIT)
    return {
        "bytes_total": total,
        "captured_bytes": len(data),
        "truncated": total > len(data),
        "prefix_sha256": hashlib.sha256(data).hexdigest(),
        "text": data.decode("utf-8", errors="backslashreplace"),
    }


def receipt_snapshot(path):
    """Observe the controlled application's bytes without accepting a late receipt."""
    path = Path(path)
    if not path.exists():
        return {"present": False, "bytes_total": 0, "captured_bytes": 0, "text": ""}
    result = capture(path)
    return {"present": True, **result}


def run_wrapper(context, arguments, *, spawn=subprocess.Popen, clock=time.monotonic_ns):
    """Wait the one actual child before closing captures or publishing terminal facts."""
    root = Path(context["directory"])
    output, errors = root / "gtk.stdout.txt", root / "gtk.stderr.txt"
    started = clock()
    child = None
    primary = None
    native_exit = None
    with output.open("xb") as out, errors.open("xb") as err:
        try:
            child = spawn(
                ["/usr/bin/gtk-launch", *arguments],
                stdin=subprocess.DEVNULL,
                stdout=out,
                stderr=err,
            )
            publish(
                root / "gtk-started.json",
                {
                    "schema": 1,
                    "nonce": context["nonce"],
                    "identity": context["identity"],
                    "wrapper_pid": os.getpid(),
                    "gtk_pid": child.pid,
                    "before_spawn_ns": started,
                    "after_spawn_ns": clock(),
                },
            )
            native_exit = child.wait()
        except BaseException as failure:
            primary = failure
        finally:
            # An elapsed observer deadline or diagnostic exception cannot drop the child.
            while child is not None and native_exit is None:
                try:
                    native_exit = child.wait()
                except BaseException as failure:
                    if primary is None:
                        primary = failure
            terminal = clock()
    packet = {
        "schema": 1,
        "nonce": context["nonce"],
        "identity": context["identity"],
        "wrapper_pid": os.getpid(),
        "gtk_pid": child.pid if child is not None else None,
        "native_exit": native_exit,
        "native_terminal_observed": native_exit is not None,
        "before_spawn_ns": started,
        "terminal_observed_ns": terminal,
        "observer_failure": type(primary).__name__ if primary is not None else "",
        "spawn_errno": primary.errno if child is None and isinstance(primary, OSError) else None,
        "stdout": capture(output),
        "stderr": capture(errors),
        "receipt_at_native_terminal": receipt_snapshot(context["receipt"]),
    }
    publish(root / "gtk-terminal.json", packet)
    if primary is not None:
        return 1
    # Normal exits preserve the actual status; signals retain their raw value in the receipt.
    return native_exit if native_exit >= 0 else 128 - native_exit


def wrapper_main():
    """Delegate the exact production operand once to the real system launcher."""
    context = json.loads(Path(os.environ["ERGOPTI_APPLICATION_DIAGNOSTIC_CONTEXT"]).read_bytes())
    if sys.argv[1:] != ["--", context["identity"]]:
        raise RuntimeError("Diagnostic wrapper received different production operands")
    return run_wrapper(context, sys.argv[1:])


def native_launch_complete(packet):
    """Only an exact successful native handoff can admit the original receipt oracle."""
    return (
        type(packet) is dict
        and packet.get("native_terminal_observed") is True
        and packet.get("observer_failure") == ""
        and type(packet.get("native_exit")) is int
        and packet["native_exit"] == 0
    )


def run_owned_case(arguments, environment):
    """Keep the acquired session process until actual completion, even on observer timeout."""
    child = subprocess.Popen(
        arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    timed_out = False
    primary = None
    communicated = False
    try:
        output, errors = child.communicate(timeout=10)
        communicated = True
    except subprocess.TimeoutExpired:
        timed_out = True
    except BaseException as failure:
        primary = failure
    finally:
        while not communicated:
            try:
                output, errors = child.communicate()
                communicated = True
            except BaseException as failure:
                if primary is None:
                    primary = failure
    if primary is not None:
        raise primary
    result = subprocess.CompletedProcess(arguments, child.returncode, output, errors)
    result.observer_timed_out = timed_out
    return result


def require_x11_ready(display_name, owned_server, *, spawn=subprocess.Popen):
    """Require one real X11 handshake, retaining its exact client through retirement."""
    if (
        not isinstance(display_name, str)
        or not display_name.startswith(":")
        or not display_name[1:].isascii()
        or not display_name[1:].isdecimal()
        or owned_server.poll() is not None
    ):
        raise RuntimeError("Owned virtual display is not available for a handshake")
    child = spawn(
        ["/usr/bin/xdpyinfo", "-display", display_name],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        status = child.wait(timeout=5)
        if type(status) is not int or status != 0 or owned_server.poll() is not None:
            raise RuntimeError("Owned virtual display refused the X11 handshake")
    finally:
        if child.returncode is None:
            while True:
                try:
                    child.kill()
                    break
                except ProcessLookupError:
                    # A native exit can race the signal; only wait can retire that owner.
                    break
                except BaseException:
                    # Retry an interrupted signal before waiting on a live blocked client.
                    continue
            while child.returncode is None:
                try:
                    child.wait()
                except BaseException:
                    # An interrupted observer cannot abandon an acquired native client.
                    continue
    return True
