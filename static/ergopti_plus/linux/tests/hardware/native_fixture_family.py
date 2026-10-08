#!/usr/bin/env python3
# tests/hardware/native_fixture_family.py

"""Supervise one exact Linux child family, including independently detached children.

Each invocation is its own subreaper. Retirement inventories only this process's
kernel children, acquires their pidfds before reaping, and never signals a PGID
or searches unrelated processes. A terminal receipt follows physical retirement;
it does not invent a Lua handle observation when a deadline required SIGKILL.
"""

import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


SIGNALS = {signal.SIGINT, signal.SIGTERM}


class Family:
    def __init__(self, command, timeout, receipt_fd, token):
        self.cancelled = 0
        self.command, self.timeout = command, timeout
        self.receipt_fd, self.token = receipt_fd, token
        self.child = None
        self.pidfds = {}
        self.reaped = set()
        self.closed = 0
        self.base = None
        self.base_identity = None
        self.failure = None
        self.debt = None
        self.grace_deadline = None
        self.namespace_absent = False
        self.namespace_removal_admitted = False
        self.settled = False
        # Handlers only publish a flag. They cannot throw between acquisition and
        # ownership publication, including inside Popen or tempfile allocation.
        for kind in SIGNALS:
            signal.signal(kind, self.cancel)
        if ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "owned subreaper admission failed")
        if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
            raise RuntimeError("owned native fixture requires pidfd support")
        # Admission must fail before ANY process or namespace allocation when
        # this kernel cannot enumerate the exact supervisor's direct children.
        self.children()

    def cancel(self, kind, _frame):
        self.cancelled = self.cancelled or kind

    def receipt(self, stage, **fields):
        packet = dict(version=1, stage=stage, token=self.token, supervisor=os.getpid(), **fields)
        payload = (json.dumps(packet, separators=(",", ":")) + "\n").encode("ascii")
        while payload:
            count = os.write(self.receipt_fd, payload)
            if count <= 0:
                raise RuntimeError("owned receipt write made no progress")
            payload = payload[count:]

    def children(self):
        # This kernel file names ONLY children of this dedicated supervisor.
        return [
            int(value)
            for value in Path(f"/proc/self/task/{os.getpid()}/children").read_text().split()
        ]

    def acquire(self, pid):
        if pid not in self.pidfds:
            # An unreaped direct child cannot have its PID reused. This authority
            # comes from our kernel children list, never a caller-provided PID.
            assert pid in self.children(), "refuse a process outside this owned family"
            self.pidfds[pid] = os.pidfd_open(pid)

    def exited(self, pid):
        if self.pidfds[pid] is None:
            assert pid in self.reaped
            return True
        return bool(select.select([self.pidfds[pid]], [], [], 0)[0])

    def send(self, pid, kind):
        if not self.exited(pid):
            try:
                assert signal.pidfd_send_signal(self.pidfds[pid], kind) is None, (
                    "native pidfd signal refused"
                )
            except ProcessLookupError:
                assert self.exited(pid), "signal refusal has no physical exit receipt"

    def reap(self, pid):
        if pid in self.reaped or not self.exited(pid):
            return
        if self.child is not None and pid == self.child.pid:
            assert type(self.child.poll()) is int, "owned leader exit was not reaped"
        else:
            result, status = os.waitpid(pid, os.WNOHANG)
            assert type(result) is int and result == pid and type(status) is int, (
                "exact adopted child exit was not reaped"
            )
        self.reaped.add(pid)

    def retirement_step(self):
        """Retry exact retained authorities; a refusal cannot release any debt."""
        if self.settled:
            return True
        try:
            current = self.children()
            for pid in current:
                self.acquire(pid)
            if self.child is not None and self.child.pid not in self.pidfds:
                self.acquire(self.child.pid)
            if self.child is not None and self.child.pid not in self.reaped:
                if self.grace_deadline is None:
                    self.send(self.child.pid, signal.SIGTERM)
                    self.grace_deadline = time.monotonic() + 0.5
                if not self.exited(self.child.pid) and time.monotonic() < self.grace_deadline:
                    return False
            # Terminating an exact owned root adopts its independent descendants
            # here. Subsequent complete censuses acquire and retire each layer.
            for pid in current:
                self.send(pid, signal.SIGKILL)
            for pid in self.pidfds:
                self.reap(pid)
                if pid in self.reaped and self.pidfds[pid] is not None:
                    assert os.close(self.pidfds[pid]) is None, "exact native pidfd close refused"
                    self.pidfds[pid] = None
                    self.closed += 1
            if self.children() or len(self.reaped) != len(self.pidfds):
                return False
            assert all(self.exited(pid) and pid in self.reaped for pid in self.pidfds)
            assert self.closed == len(self.pidfds)
            if self.base is not None and not self.namespace_absent:
                if not self.namespace_removal_admitted:
                    stat = self.base.lstat()
                    assert (stat.st_dev, stat.st_ino) == self.base_identity, (
                        "owned namespace identity changed"
                    )
                    assert shutil.rmtree(self.base) is None, "owned namespace removal refused"
                    self.namespace_removal_admitted = True
                try:
                    self.base.lstat()
                except FileNotFoundError as error:
                    assert error.errno == 2, "namespace absence has no exact native receipt"
                else:
                    raise AssertionError("owned namespace remained after retirement")
            self.namespace_absent = True
            self.debt = None
            self.settled = True
            return True
        except Exception as error:
            # Keep the exact child/pidfd/namespace capabilities and their last
            # positive observations. Unknown census, failed signal, wait, close
            # or namespace removal never becomes an empty-family receipt.
            self.debt = {
                "type": type(error).__name__,
                "errno": getattr(error, "errno", None),
            }
            return False

    def retire(self):
        """Retain ownership across refusals until actual physical settlement."""
        report_at = time.monotonic() + 10
        while not self.retirement_step():
            if time.monotonic() >= report_at:
                try:
                    print(
                        "FAIL native fixture retirement retains physical debt",
                        file=sys.stderr,
                        flush=True,
                    )
                except Exception:
                    pass
                report_at = time.monotonic() + 10
            time.sleep(0.005)
        return True

    def report_failure(self, reason, exception_type=None):
        """Observe only this supervisor's unreaped children; never grant success."""
        packet = {"reason": reason, "supervisor": os.getpid()}
        if exception_type is not None:
            packet["exception_type"] = exception_type
        try:
            owned = self.children()
            packet["owned_count"] = len(owned)
            packet["truncated"] = len(owned) > 32
            rows = []
            for pid in owned[:32]:
                # These are unreaped direct children from our kernel census.
                # No arguments, environment or arbitrary process data are read.
                row = {"pid": pid}
                try:
                    with Path(f"/proc/{pid}/status").open("rb") as source:
                        status = source.read(4096).decode("ascii", errors="replace")
                    for line in status.splitlines():
                        key, separator, value = line.partition(":")
                        if separator and key in {"State", "PPid"}:
                            row[key] = value.strip()[:64]
                    with Path(f"/proc/{pid}/comm").open("rb") as source:
                        row["comm"] = source.read(64).decode("ascii", errors="replace").strip()
                except Exception as error:
                    row["observation_error"] = type(error).__name__
                rows.append(row)
            packet["owned"] = rows
        except Exception as error:
            packet["census_error"] = type(error).__name__
        try:
            print(
                "NATIVE_FAMILY_FAILURE " + json.dumps(packet, separators=(",", ":")),
                file=sys.stderr,
                flush=True,
            )
        except Exception:
            # A refused diagnostic must not replace the original status/debt.
            pass

    def run(self):
        status = 1
        try:
            self.base = Path(tempfile.mkdtemp(prefix="ergopti-native-family-"))
            self.base.chmod(0o700)
            stat = self.base.lstat()
            self.base_identity = stat.st_dev, stat.st_ino
            self.receipt("ready")
            if self.cancelled:
                status = 128 + self.cancelled
            else:
                # Flag-only handlers cannot interrupt Popen -> pidfd publication.
                # Do not mask across exec: a child would inherit the blocked mask
                # and could miss its graceful shutdown. The target does not
                # inherit this supervisor's terminal receipt descriptor.
                self.child = subprocess.Popen(
                    self.command,
                    env=dict(os.environ, TMPDIR=str(self.base)),
                    close_fds=True,
                )
                self.acquire(self.child.pid)
                deadline = time.monotonic() + self.timeout
                while True:
                    result = self.child.poll()
                    if result is not None:
                        assert type(result) is int and self.exited(self.child.pid), (
                            "native leader exit lacks physical receipt"
                        )
                        self.reaped.add(self.child.pid)
                        status = result if result >= 0 else 128 - result
                        break
                    if self.cancelled:
                        status = 128 + self.cancelled
                        break
                    if time.monotonic() >= deadline:
                        status = 124
                        break
                    time.sleep(0.005)
                # A successful leader cannot certify live orphan descendants.
                if status == 0 and self.children():
                    status = 1
                    self.report_failure("leader-exit-with-owned-children")
        except BaseException as error:
            self.failure = type(error).__name__
            status = 1
            self.report_failure("supervisor-exception", self.failure)
        finally:
            assert self.retire() is True and self.settled and self.namespace_absent
        self.receipt(
            "settled",
            status=status,
            acquired=len(self.pidfds),
            reaped=len(self.reaped),
            closed=self.closed,
            namespace_absent=True,
        )
        os.close(self.receipt_fd)
        return status


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--receipt-fd", required=True, type=int)
    parser.add_argument("--token", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    assert command and 0 < args.timeout <= 180
    try:
        family = Family(command, args.timeout, args.receipt_fd, args.token)
    except Exception:
        # Constructor admission performs no child/namespace allocation. This
        # exact refusal distinguishes a safe boundary from a lost positive READY
        # owner. It remains a failed native prerequisite, never success.
        packet = dict(
            version=1,
            stage="refused",
            token=args.token,
            supervisor=os.getpid(),
            status=1,
            acquired=0,
            reaped=0,
            closed=0,
            namespace_absent=True,
        )
        os.write(args.receipt_fd, (json.dumps(packet) + "\n").encode("ascii"))
        os.close(args.receipt_fd)
        return 1
    return family.run()


def run(command, *, timeout, cwd=None, env=None, text=True, capture_output=True):
    """Run a nested family; its terminal receipt precedes returning any status."""
    reader, writer = os.pipe()
    token = uuid.uuid4().hex
    child = None
    try:
        child = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--timeout",
                str(timeout),
                "--receipt-fd",
                str(writer),
                "--token",
                token,
                "--",
                *command,
            ],
            cwd=cwd,
            env=env,
            pass_fds=(writer,),
            text=text,
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_output else None,
        )
        os.close(writer)
        writer = None
        # The nested helper owns its deadline. Killing only this supervisor on a
        # communicate timeout would recreate the detached-descendant gap.
        stdout, stderr = child.communicate()
        packets = b""
        while True:
            chunk = os.read(reader, 4096)
            if not chunk:
                break
            packets += chunk
            assert len(packets) <= 4096, "owned receipt stream exceeded its bound"
        frames = [json.loads(line) for line in packets.splitlines()]
        assert len(frames) == 2 and [row["stage"] for row in frames] == [
            "ready",
            "settled",
        ]
        assert all(row["token"] == token and row["supervisor"] == child.pid for row in frames)
        terminal = frames[-1]
        assert terminal["namespace_absent"] is True
        assert terminal["acquired"] == terminal["reaped"] == terminal["closed"]
        assert terminal["status"] == child.returncode
        if child.returncode == 124:
            raise subprocess.TimeoutExpired(command, timeout, output=stdout, stderr=stderr)
        return subprocess.CompletedProcess(command, child.returncode, stdout, stderr)
    finally:
        os.close(reader)
        if writer is not None:
            os.close(writer)


if __name__ == "__main__":
    raise SystemExit(main())
