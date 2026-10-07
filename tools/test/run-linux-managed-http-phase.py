# tools/test/run-linux-managed-http-phase.py

"""Keep one native qualification owner alive until its real closure is admitted.

This launcher never wraps public30 in another process/subreaper. Its exact
fixture runs as __main__ in this same PID; its original cleanup remains owner.
Output18 delegates the existing guardian's native calls and sole reaper.
Simple build commands use the canonical proc identities and kernel reservation.
Unknown native or publication closure retains this process and private inputs.
"""

from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import threading
import time
import types


retained_protocols = []


def source(path, expected, protocol):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    owner = {"fd": fd, "state": "open"}
    protocol.files.append(owner)
    primary = None
    try:
        fact = os.fstat(fd)
        if not stat.S_ISREG(fact.st_mode) or fact.st_size > 1048576:
            raise RuntimeError("Phase source admission refused")
        chunks = bytearray()
        while len(chunks) <= 1048576:
            block = os.read(fd, 65536)
            if not block:
                break
            chunks.extend(block)
        if len(chunks) != fact.st_size or hashlib.sha256(chunks).hexdigest() != expected:
            raise RuntimeError("Phase source identity refused")
        return bytes(chunks)
    except BaseException as error:
        primary = error
        raise
    finally:
        owner["state"] = "closing"
        try:
            os.close(fd)
            owner["state"] = "closed"
        except BaseException:
            owner["state"] = "uncertain-close"
            protocol.debt = True
            if primary is None:
                raise


def private_primary(error):
    """Fixed exception kind and bounded basename/line only; never inspect message/locals."""
    kinds = {
        RuntimeError: "RuntimeError",
        AssertionError: "AssertionError",
        ValueError: "ValueError",
        TypeError: "TypeError",
        KeyError: "KeyError",
        OSError: "OSError",
        FileNotFoundError: "FileNotFoundError",
        PermissionError: "PermissionError",
        ImportError: "ImportError",
        ModuleNotFoundError: "ModuleNotFoundError",
        SyntaxError: "SyntaxError",
        UnicodeError: "UnicodeError",
        KeyboardInterrupt: "KeyboardInterrupt",
        SystemExit: "SystemExit",
    }
    frames = []
    cursor = BaseException.__traceback__.__get__(error)
    for _ in range(64):
        if cursor is None:
            break
        basename = Path(cursor.tb_frame.f_code.co_filename).name
        if re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", basename) is None:
            basename = "unavailable"
        line = cursor.tb_lineno
        frames.append({"file": basename, "line": line if 0 < line < 2147483648 else 0})
        cursor = cursor.tb_next
    return {"exception": kinds.get(type(error), "OtherException"), "frames": frames[-6:]}


class Protocol:
    def __init__(self, directory, kind):
        fact = directory.lstat()
        if (
            not stat.S_ISDIR(fact.st_mode)
            or fact.st_uid != os.geteuid()
            or stat.S_IMODE(fact.st_mode) != 0o700
        ):
            raise RuntimeError("Private phase receipt directory refused")
        self.directory, self.kind = directory, kind
        self.files = []
        self.debt = False
        retained_protocols.append(self)

    def publish(self, state, status, cancelled, diagnostic=None):
        # Fixed three exclusive checkpoints. Never replace an earlier refusal.
        path = self.directory / (state + ".json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        owner = {"fd": fd, "state": "open"}
        self.files.append(owner)
        try:
            fact = os.fstat(fd)
            if (
                not stat.S_ISREG(fact.st_mode)
                or fact.st_uid != os.geteuid()
                or fact.st_nlink != 1
                or stat.S_IMODE(fact.st_mode) != 0o600
            ):
                raise RuntimeError("Private phase receipt admission refused")
            value = {
                "schema": 1,
                "phase": self.kind,
                "pid": os.getpid(),
                "state": state,
                "status": status,
                "cancelled": cancelled,
            }
            if diagnostic is not None:
                if state != "diagnostic" or status != 1:
                    raise RuntimeError("Private diagnostic state refused")
                value["primary"] = diagnostic
            data = (json.dumps(value, sort_keys=True) + "\n").encode("ascii")
            if len(data) > 1024 or os.write(fd, data) != len(data):
                raise RuntimeError("Private phase receipt publication refused")
            os.fsync(fd)
            after = os.stat(path, follow_symlinks=False)
            if (
                after.st_dev,
                after.st_ino,
                after.st_uid,
                after.st_nlink,
                stat.S_IMODE(after.st_mode),
            ) != (fact.st_dev, fact.st_ino, os.geteuid(), 1, 0o600):
                raise RuntimeError("Private phase receipt identity changed")
        except BaseException:
            self.debt = True
            raise
        finally:
            owner["state"] = "closing"
            try:
                os.close(fd)
                owner["state"] = "closed"
            except BaseException:
                owner["state"] = "uncertain-close"
                self.debt = True


def command(owner, arguments, seconds, cancelled):
    """One sole build-command reaper, raw inherited private stdout/stderr sinks."""
    process, old_subreaper, primary, result = None, None, None, 1
    birth = None
    rescued = False
    deadline = time.monotonic() + seconds

    def reserved():
        nonlocal birth
        observed = owner.observe_child(process.pid)  # WNOWAIT, no competing reap.
        fact = owner.process_fact(process.pid)
        if birth is None:
            birth = fact["birth"]
        if fact["birth"] != birth or fact["group"] != process.pid or fact["session"] != process.pid:
            raise RuntimeError("Owned phase leader reservation lost")
        return observed

    try:
        if owner.direct_children():
            raise RuntimeError("Exclusive phase command admission refused")
        owner.group_live_members(os.getpid())
        old_subreaper = owner.subreaper(True)
        if cancelled() or time.monotonic() >= deadline:
            raise RuntimeError("Phase command already cancelled")
        process = subprocess.Popen(arguments, start_new_session=True)
        birth = owner.process_fact(process.pid)["birth"]
        while True:
            observed = reserved()
            if cancelled() or time.monotonic() >= deadline:
                raise RuntimeError("Phase command deadline refused")
            if observed is not None:
                result = (
                    observed.si_status if observed.si_code == os.CLD_EXITED else -observed.si_status
                )
                break
            time.sleep(0.01)
    except BaseException as error:
        primary = error
    finally:
        # A live reservation is retained until every original/adopted child is
        # physically terminal. Repeated TERM only toggles cancelled(), never
        # interrupts this cleanup or substitutes for kernel wait receipts.
        while old_subreaper is not None:
            try:
                if process is not None:
                    reserved()
                    if owner.group_live_members(process.pid):
                        reserved()
                        rescued = True
                        os.killpg(process.pid, signal.SIGKILL)
                children = owner.direct_children()
                if process is not None and process.pid not in children:
                    raise RuntimeError("Owned phase reservation disappeared")
                for pid in children:
                    if process is not None and pid == process.pid:
                        continue
                    observed = owner.observe_child(pid)
                    if observed is None:
                        rescued = True
                        os.kill(pid, signal.SIGKILL)
                    elif os.waitpid(pid, 0)[0] != pid:
                        raise RuntimeError("Adopted phase child retirement refused")
                if process is None:
                    if owner.direct_children():
                        time.sleep(0.02)
                        continue
                else:
                    if owner.group_live_members(process.pid) or owner.direct_children() != [
                        process.pid
                    ]:
                        time.sleep(0.02)
                        continue
                    if reserved() is None:
                        time.sleep(0.02)
                        continue
                    reaped, wait_status = os.waitpid(process.pid, 0)
                    if reaped != process.pid:
                        raise RuntimeError("Phase leader reap refused")
                    process.returncode = os.waitstatus_to_exitcode(wait_status)
                    process = None
                owner.subreaper(old_subreaper)
                old_subreaper = None
            except (RuntimeError, owner.RuntimeRefused, OSError) as error:
                if primary is None:
                    primary = error
                time.sleep(0.02)  # Retain actual debt; never declare closure.
    return 1 if primary is not None or cancelled() or rescued else result


def phase_main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--owner", type=Path, required=True)
    parser.add_argument("--owner-sha256", required=True)
    parser.add_argument(
        "--kind", choices=("command", "output18", "public30", "archive"), required=True
    )
    parser.add_argument("--fixture-sha256")
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--budget", type=float, required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not 0 < args.budget <= 1800:
        raise RuntimeError("Finite phase budget required")
    if (
        not args.owner.is_absolute()
        or not args.receipt.is_absolute()
        or re.fullmatch(r"[0-9a-f]{64}", args.owner_sha256) is None
    ):
        raise RuntimeError("Literal phase input admission refused")
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    if not arguments:
        raise RuntimeError("Literal phase command required")
    cancelled = [False]
    signal.signal(signal.SIGTERM, lambda signum, frame: cancelled.__setitem__(0, True))
    signal.signal(signal.SIGINT, lambda signum, frame: cancelled.__setitem__(0, True))
    protocol = Protocol(args.receipt, args.kind)
    raw = source(args.owner, args.owner_sha256, protocol)
    module = types.ModuleType("owned_managed_phase_kernel")
    module.__file__ = str(args.owner)
    exec(compile(raw, str(args.owner), "exec"), module.__dict__)
    # The canonical inspector itself guards exact self PID-view and birth.
    if module.direct_children():
        raise RuntimeError("Exclusive phase owner required")
    protocol.publish("started", None, False)
    status, fixture, original_subreaper = 1, None, module.subreaper()
    primary = None
    try:
        if cancelled[0]:
            raise KeyboardInterrupt()
        if args.kind == "command":
            status = command(module, arguments, args.budget, lambda: cancelled[0])
        else:
            if len(arguments) < 3 or arguments[1] != "-B":
                raise RuntimeError("Literal Python fixture command required")
            script = Path(arguments[2])
            if (
                not script.is_absolute()
                or re.fullmatch(r"[0-9a-f]{64}", args.fixture_sha256 or "") is None
            ):
                raise RuntimeError("Literal fixture source identity required")
            raw = source(script, args.fixture_sha256, protocol)
            if args.kind == "output18":
                fixture = types.ModuleType("owned_original_output_guardian")
                fixture.__file__ = str(script)
                exec(compile(raw, str(script), "exec"), fixture.__dict__)
                original_reap, original_retire = fixture.reap_available, fixture.retire_remaining
                guard = {"cleanup": False, "interruption": False}

                def reap(child, state):
                    original_reap(child, state)  # Exactly one original delegate.
                    if cancelled[0] and not guard["cleanup"] and not guard["interruption"]:
                        guard["interruption"] = True
                        raise KeyboardInterrupt("Owned output phase cancelled")

                def retire(child, state):
                    guard["cleanup"] = True
                    return original_retire(child, state)

                fixture.reap_available, fixture.retire_remaining = reap, retire
                if cancelled[0]:
                    raise KeyboardInterrupt("Owned output phase cancelled before fixture dispatch")
                status = fixture.main(arguments[3:])
            elif args.kind == "archive":
                if script.name != "run_updater_archive_pipeline.py":
                    raise RuntimeError("Literal archive fixture required")
                fixture = types.ModuleType("__main__")
                fixture.__file__, fixture.__package__ = str(script), None
                sys.modules["__main__"] = fixture
                sys.argv, sys.path[0] = [str(script), *arguments[3:]], str(script.parent)

                # Signals only collect intent. The same source-admitted guardian
                # enters its own reap/retire ports before cooperative interruption.
                def archive_interrupted(signum, frame):
                    cancelled[0] = True

                original_exec = exec

                def archive_exec(code, namespace, locals_value=None):
                    original_exec(code, namespace, locals_value)
                    if namespace.get("__name__") != "pipeline_original_native_guardian":
                        return
                    original_reap = namespace["reap_available"]
                    original_retire = namespace["retire_remaining"]
                    original_main = namespace["main"]
                    guard = {"cleanup": False, "interruption": False}

                    def archive_reap(child, state):
                        original_reap(child, state)  # The sole original reaper.
                        if cancelled[0] and not guard["cleanup"] and not guard["interruption"]:
                            guard["interruption"] = True
                            raise KeyboardInterrupt("Owned archive phase cancelled")

                    def archive_retire(child, state):
                        guard["cleanup"] = True
                        return original_retire(child, state)

                    def archive_guardian(arguments):
                        if cancelled[0]:
                            raise KeyboardInterrupt(
                                "Owned archive cancelled before original child admission"
                            )
                        guard["cleanup"], guard["interruption"] = False, False
                        return original_main(arguments)

                    namespace["reap_available"], namespace["retire_remaining"] = (
                        archive_reap,
                        archive_retire,
                    )
                    namespace["main"] = archive_guardian

                fixture.__dict__["exec"] = archive_exec
                signal.signal(signal.SIGTERM, archive_interrupted)
                signal.signal(signal.SIGINT, archive_interrupted)
                try:
                    if cancelled[0]:
                        raise KeyboardInterrupt(
                            "Owned archive phase cancelled before fixture dispatch"
                        )
                    original_exec(compile(raw, str(script), "exec"), fixture.__dict__)
                    status = 0
                except SystemExit as outcome:
                    status = (
                        outcome.code
                        if isinstance(outcome.code, int)
                        else (0 if outcome.code is None else 1)
                    )
            else:
                fixture = types.ModuleType("__main__")
                fixture.__file__, fixture.__package__ = str(script), None
                sys.modules["__main__"] = fixture
                sys.argv, sys.path[0] = [str(script), *arguments[3:]], str(script.parent)

                def interrupted(signum, frame):
                    cancelled[0] = True
                    raise KeyboardInterrupt("Owned public phase cancelled")

                signal.signal(signal.SIGTERM, interrupted)
                signal.signal(signal.SIGINT, interrupted)
                try:
                    if cancelled[0]:
                        raise KeyboardInterrupt(
                            "Owned public phase cancelled before fixture dispatch"
                        )
                    exec(compile(raw, str(script), "exec"), fixture.__dict__)
                    status = 0
                except SystemExit as outcome:
                    status = (
                        outcome.code
                        if isinstance(outcome.code, int)
                        else (0 if outcome.code is None else 1)
                    )
    except BaseException as error:
        primary = error  # Retain primary privately; export no raw exception.
        if isinstance(error, KeyboardInterrupt):
            cancelled[0] = True
        status = 1
    finally:
        # Cleanup/retained-state observation must not be interrupted a second
        # time. Public30's original in-exec handler already drove its teardown.
        signal.signal(signal.SIGTERM, lambda signum, frame: cancelled.__setitem__(0, True))
        signal.signal(signal.SIGINT, lambda signum, frame: cancelled.__setitem__(0, True))
    if args.kind == "archive" and primary is not None:
        try:
            # Same exact private receipt/FD owner; failure cannot become success.
            protocol.publish("diagnostic", 1, cancelled[0], private_primary(primary))
        except BaseException:
            protocol.debt = True
    retained_published = False
    while True:
        try:
            closed = not module.direct_children()
            if args.kind == "public30" and fixture is not None:
                for name in ("NativePublicControls", "PerHopControls"):
                    cls = fixture.__dict__.get(name)
                    if cls is not None and "root" in cls.__dict__:
                        closed = closed and cls.__dict__.get("resources_closed") is True
                closed = closed and not any(
                    t is not threading.current_thread() and t.is_alive()
                    for t in threading.enumerate()
                )
            if args.kind == "archive" and fixture is not None:
                closed = closed and not fixture.__dict__.get("RETAINED_TLS_OWNERS", [])
                closed = closed and not any(
                    t is not threading.current_thread() and t.is_alive()
                    for t in threading.enumerate()
                )
            if closed and not protocol.debt:
                module.subreaper(original_subreaper)
                final_status = 0 if primary is None and not cancelled[0] and status == 0 else 1
                protocol.publish("closed", final_status, cancelled[0])
                if not protocol.debt:
                    return final_status
        except BaseException as error:
            # No new waiter, destructive census action or guessed cleanup.
            # Keep the first refusal even if a later read can observe closure.
            if primary is None:
                primary = error
            status = 1
        if not retained_published:
            retained_published = True
            try:
                protocol.publish("retained", 1, cancelled[0])
            except BaseException:
                protocol.debt = True
        time.sleep(0.05)


def main():
    try:
        return phase_main()
    except BaseException:
        # Preparation acquired no native children. Exact uncertain diagnostic
        # descriptors still retain their owner; never retry a bare integer.
        sys.stderr.write("Owned native phase preparation refused; private state retained.\n")
        signal.signal(signal.SIGTERM, lambda signum, frame: None)
        signal.signal(signal.SIGINT, lambda signum, frame: None)
        while any(protocol.debt for protocol in retained_protocols):
            time.sleep(0.05)
        return 1


if __name__ == "__main__":
    sys.exit(main())
