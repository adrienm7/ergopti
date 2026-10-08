#!/usr/bin/env python3
# tools/diagnostics/apple_shortcuts_cold_cli_probe.py
"""Observe one cold public CLI request without qualifying a Shortcuts provider."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

COMMAND = ("/usr/bin/shortcuts", "list", "--show-identifiers")
LIMIT = 65536
DEADLINE_SECONDS = 20
CONTRACT = "macos-shortcuts-cold-cli-observation"


class ObservationRefused(ValueError):
    """Expose a fixed cause without private command output or exception text."""

    def __init__(self, cause):
        super().__init__("Cold CLI observation refused")
        self.cause = cause


def require(condition, cause):
    if condition is not True:
        raise ObservationRefused(cause)


def private_directory(path):
    """Admit the exact acquired private directory before opening captures."""
    info = path.lstat()
    require(
        stat.S_ISDIR(info.st_mode)
        and not stat.S_ISLNK(info.st_mode)
        and stat.S_IMODE(info.st_mode) == 0o700
        and info.st_uid == os.getuid()
        and path.resolve() == path,
        "private_root_refused",
    )


def interrupted(error, ownership):
    """Recognize cancellation from the genuine process owner and BaseException."""
    return not isinstance(error, Exception) or isinstance(error, ownership.OwnedProcessInterrupted)


def terminal_packet(observation, group):
    """Copy only a nonreaping terminal tuple bound to the acquired child."""
    values = [getattr(observation, key, None) for key in ("si_pid", "si_code", "si_status")]
    require(
        all(type(value) is int for value in values)
        and values[0] == group.process.pid
        and values[0] > 0
        and values[1] in (1, 2, 3)
        and 0 <= values[2] <= 255,
        "terminal_shape_refused",
    )
    return dict(zip(("pid", "code", "status"), values))


class ColdCliAttempt:
    """Retain the exact process and capture descriptors until physical retirement."""

    def __init__(self, private_parent, ownership):
        self.ownership = ownership
        self.groups = []
        self.streams = []
        self.closed_streams = set()
        self.retirement_ack = False
        self.primary = None
        self.cleanup_error = None
        self.terminal = None
        self.failure = "none"
        self.capture_facts = {"available": False, "failure": "not_observed"}
        self.elapsed_us = None
        self.completed_at = None
        self.private_root = Path(
            tempfile.mkdtemp(prefix="ergopti-shortcuts-cold-", dir=private_parent)
        )
        private_directory(self.private_root)
        try:
            for name in ("stdout", "stderr"):
                descriptor = os.open(
                    self.private_root / name,
                    os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                )
                try:
                    stream = os.fdopen(descriptor, "r+b", buffering=0)
                except BaseException:
                    os.close(descriptor)
                    raise
                # Register the acquired stream before any metadata observation.
                self.streams.append(stream)
        except BaseException:
            self.retirement_ack = True  # No process acquisition has been attempted.
            self.close_captures()
            raise

    def register(self, group):
        """Keep the actual acquisition before delivering a handoff refusal."""
        self.groups.append(group)
        require(len(self.groups) == 1, "duplicate_acquisition_refused")

    def retire(self):
        """A false or throwing settlement never closes captures or grants an ACK."""
        if self.retirement_ack:
            return
        for group in self.groups:
            require(group.settle() is True, "retirement_refused")
            require(
                group.receipt()["closed"] is True
                and type(group.process.returncode) is int
                and -255 <= group.process.returncode <= 255,
                "retirement_refused",
            )
        self.retirement_ack = True

    def observe_captures(self):
        """Read bounded bytes only after the writer's actual retirement ACK."""
        require(self.retirement_ack, "unretired_capture_refused")
        facts = {}
        for name, stream in zip(("stdout", "stderr"), self.streams):
            descriptor = stream.fileno()
            before = os.fstat(descriptor)
            require(
                stat.S_ISREG(before.st_mode)
                and stat.S_IMODE(before.st_mode) == 0o600
                and before.st_uid == os.getuid()
                and 0 <= before.st_size <= LIMIT,
                "capture_refused",
            )
            os.lseek(descriptor, 0, os.SEEK_SET)
            raw = bytearray()
            while len(raw) <= LIMIT:
                block = os.read(descriptor, min(8192, LIMIT + 1 - len(raw)))
                if not block:
                    break
                raw.extend(block)
            after = os.fstat(descriptor)
            require(
                len(raw) == before.st_size
                and tuple(
                    getattr(before, key)
                    for key in (
                        "st_dev",
                        "st_ino",
                        "st_uid",
                        "st_size",
                        "st_mode",
                        "st_mtime_ns",
                        "st_ctime_ns",
                    )
                )
                == tuple(
                    getattr(after, key)
                    for key in (
                        "st_dev",
                        "st_ino",
                        "st_uid",
                        "st_size",
                        "st_mode",
                        "st_mtime_ns",
                        "st_ctime_ns",
                    )
                ),
                "capture_changed",
            )
            facts[name] = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
        self.capture_facts = {"available": True, "failure": "none", **facts}

    def close_captures(self):
        """Release each original capture only after exact process retirement."""
        require(self.retirement_ack, "unretired_capture_refused")
        for index, stream in enumerate(self.streams):
            if index not in self.closed_streams:
                stream.close()
                self.closed_streams.add(index)

    def execute(self, native, clock=time.monotonic, sleep=time.sleep, started=None):
        """Make one CLI acquisition, retaining the original failure through cleanup."""
        if started is None:
            started = clock()
        deadline = started + DEADLINE_SECONDS
        try:
            require(clock() < deadline, "deadline")
            group = self.ownership.acquire_owned(
                list(COMMAND), native, self.register, stdout=self.streams[0], stderr=self.streams[1]
            )
            require(len(self.groups) == 1 and self.groups[0] is group, "acquisition_refused")
            while True:
                observation = group.observe_exit()
                if observation is not None:
                    self.terminal = terminal_packet(observation, group)
                # Retain the real terminal, but never admit a late observation.
                require(clock() < deadline, "deadline")
                if observation is not None:
                    break
                require(
                    all(os.fstat(stream.fileno()).st_size <= LIMIT for stream in self.streams),
                    "output_bound",
                )
                sleep(0.02)
        except BaseException as error:
            self.primary = error
            self.failure = (
                error.cause
                if isinstance(error, ObservationRefused)
                else "interrupted"
                if interrupted(error, self.ownership)
                else "acquisition_or_capture_refused"
            )
        finally:
            try:
                self.retire()
                self.observe_captures()
                self.close_captures()
            except BaseException as error:
                self.cleanup_error = error
                self.capture_facts = {"available": False, "failure": "cleanup_refused"}
            try:
                self.completed_at = clock()
                self.elapsed_us = min(
                    86400000000, max(0, int((self.completed_at - started) * 1000000))
                )
            except BaseException as error:
                if self.cleanup_error is None or interrupted(error, self.ownership):
                    self.cleanup_error = error
        if self.cleanup_error is not None and (
            self.primary is None or interrupted(self.cleanup_error, self.ownership)
        ):
            raise self.cleanup_error
        if self.primary is not None:
            raise self.primary
        if self.completed_at >= deadline:
            self.failure = "deadline"
            raise ObservationRefused("deadline")
        if not (
            self.terminal is not None
            and self.terminal["code"] == 1
            and self.terminal["status"] == 0
            and self.groups[0].process.returncode == 0
        ):
            self.failure = "native_exit_refused"
            raise ObservationRefused("native_exit_refused")

    def report(self):
        """Publish fixed scalar facts; never names, IDs, paths or capture bytes."""
        return {
            "schema": 1,
            "contract": CONTRACT,
            "feature_qualified": False,
            "invocation_qualified": False,
            "automation_cancellation_qualified": False,
            "permission": "not_determined",
            "failure": self.failure,
            "cleanup_failure": "none" if self.cleanup_error is None else "cleanup_refused",
            "terminal_before_retirement": self.terminal,
            "elapsed_us": self.elapsed_us,
            "retirement_ack": self.retirement_ack,
            "groups": [group.receipt() for group in self.groups],
            "retired_exit": self.groups[0].process.returncode
            if self.retirement_ack and self.groups
            else None,
            "captures": self.capture_facts,
        }


def main():
    """Run only on Darwin against the exact committed probe and ownership source."""
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--private-parent", type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == "darwin" and sys.version_info >= (3, 13), "native_prerequisite_refused")
    require(re.fullmatch("[0-9a-f]{40}", args.source_sha) is not None, "source_identity_refused")
    root = args.source_root.resolve()
    owner_path = root / "tools/diagnostics/macos_owned_process.py"
    for source in (Path(__file__).resolve(), owner_path):
        require(
            source.read_bytes()
            == subprocess.check_output(
                ["git", "show", args.source_sha + ":" + str(source.relative_to(root))], cwd=root
            ),
            "source_identity_refused",
        )
    tool = Path(COMMAND[0]).lstat()
    require(
        stat.S_ISREG(tool.st_mode) and tool.st_uid == 0 and bool(tool.st_mode & 0o111),
        "cli_identity_refused",
    )
    spec = importlib.util.spec_from_file_location("cold_cli_native_owner", owner_path)
    ownership = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ownership)
    native = ownership.NativeProcessGroups()
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    private_directory(args.output)
    args.private_parent.mkdir(mode=0o700, exist_ok=False)
    private_directory(args.private_parent)
    require(
        args.private_parent != args.output and args.output not in args.private_parent.parents,
        "private_root_refused",
    )
    attempt = ColdCliAttempt(args.private_parent, ownership)

    def cancel(_signal, _frame):
        raise ownership.OwnedProcessInterrupted("Cold CLI observation interrupted")

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, cancel)
    status = 0
    publication_failed = False
    try:
        try:
            attempt.execute(native, clock=time.monotonic, sleep=time.sleep, started=started)
        except BaseException:
            status = 1
        try:
            packet = attempt.report()
            packet["source_sha"] = args.source_sha
            ownership.exclusive_receipt(args.output / "observation.json", packet)
        except BaseException:
            status = 1
            publication_failed = True
    finally:
        # Recovery is outside the query budget and cannot promote this run.
        # Neither diagnostic IO nor another cancellation may bypass this debt.
        while not attempt.retirement_ack:
            try:
                attempt.retire()
            except BaseException:
                status = 1
                try:
                    time.sleep(0.02)
                except BaseException:
                    status = 1
        try:
            attempt.close_captures()
        except BaseException:
            status = 1
    if publication_failed:
        try:
            print(
                json.dumps(
                    {
                        "contract": CONTRACT,
                        "feature_qualified": False,
                        "failure": "publication_refused",
                    }
                )
            )
        except BaseException:
            status = 1
    return status


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except BaseException as failure:
        print(
            json.dumps(
                {
                    "contract": CONTRACT,
                    "feature_qualified": False,
                    "failure": failure.cause
                    if isinstance(failure, ObservationRefused)
                    else "observer_refused",
                }
            )
        )
        raise SystemExit(1)
