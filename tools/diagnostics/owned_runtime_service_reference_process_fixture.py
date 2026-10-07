"""Read-only actual-Mac worker fixture; prerequisites are produced separately."""

import argparse
import os
from pathlib import Path
import signal
import stat
import sys
import time

import hs274_native_build as roots
import macos_owned_process as owner

ROLE = "--owned-runtime-service-reference"
CASES = ("current", "eof", "invalid", "truncated", "overlong", "extra", "adhoc", "killed")
ALLOWED = {
    "V1 HELD",
    "V1 CURRENT 1",
    "V1 CURRENT 0",
    "V1 RETIRE_REFUSED",
    *("V1 REFUSED " + reason for reason in ("principal", "source", "policy", "signature")),
    *(
        "V1 RETIRED " + reason
        for reason in ("command", "eof", "input", "deadline", "changed", "unavailable", "output")
    ),
}


class FixtureRefusal(RuntimeError):
    """Closed refusal preserves private fixture evidence."""


def require(condition):
    if not condition:
        raise FixtureRefusal("Native owned-runtime reference fixture refused")


def marker(path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        require(os.write(descriptor, b"READY\n") == 6)
    finally:
        os.close(descriptor)


def bridge(app, output, extra):
    """Replace this reserved leader with real Main; private FIFO only changes stdin."""
    output = roots.validate_owner_root(output)
    descriptor = os.open(output / "stdin", os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        value = os.fstat(descriptor)
        require(stat.S_ISFIFO(value.st_mode) and value.st_uid == os.getuid())
        require(stat.S_IMODE(value.st_mode) == 0o600)
        marker(output / "ready")
        deadline = time.monotonic() + 20
        while not (output / "start").exists():
            require(time.monotonic() < deadline)
            time.sleep(0.01)
        require((output / "start").read_bytes() == b"READY\n")
        os.dup2(descriptor, 0)
    finally:
        os.close(descriptor)
    executable = app / "Contents/MacOS/ErgoptiPlus"
    os.execv(executable, [str(executable), ROLE] + (["--unexpected"] if extra else []))


def lines_from(path, *, complete=False):
    with path.open("rb") as stream:
        data = stream.read(513)
    require(len(data) <= 512)
    if data and not data.endswith(b"\n"):
        require(not complete)
        prefix, _, pending = data.rpartition(b"\n")
        require(any(line.encode("ascii").startswith(pending) for line in ALLOWED))
        data = prefix
    try:
        lines = data.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise FixtureRefusal("Native owned-runtime reference fixture refused") from error
    require(all(line in ALLOWED for line in lines))
    return lines


def wait_until(group, deadline, predicate):
    while True:
        if predicate():
            return
        require(group.observe_exit() is None and time.monotonic() < deadline)
        time.sleep(0.01)


def run(app, root, case):
    """Own the genuine native leader/group; worker observations do not grant authority."""
    require(sys.platform == "darwin" and sys.version_info >= (3, 13) and case in CASES)
    root = roots.validate_owner_root(root)
    app = Path(app)
    require(app.is_absolute() and app.resolve(strict=True) == app and app.suffix == ".app")
    executable = app / "Contents/MacOS/ErgoptiPlus"
    value = executable.lstat()
    require(stat.S_ISREG(value.st_mode) and value.st_nlink == 1 and os.access(executable, os.X_OK))
    # App is a test locator only. Only the actual executing Main can acquire native code proof.
    native = owner.NativeProcessGroups()
    output = root / "wp6-reference"
    output.mkdir(mode=0o700)
    os.mkfifo(output / "stdin", 0o600)
    group = None
    writer = None
    failure = None
    terminal = None
    handlers = {}
    deadline = time.monotonic() + 25

    def register(acquired):
        nonlocal group
        group = acquired

    def interrupted(_signum, _frame):
        raise owner.OwnedProcessInterrupted("Native reference fixture interrupted")

    try:
        for number in (signal.SIGTERM, signal.SIGINT):
            handlers[number] = signal.getsignal(number)
            signal.signal(number, interrupted)
        with (output / "stdout").open("xb") as stdout, (output / "stderr").open("xb") as stderr:
            owner.acquire_owned(
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "--bridge",
                    "--app",
                    str(app),
                    "--owner",
                    str(output),
                ]
                + (["--extra"] if case == "extra" else []),
                native,
                register,
                stdout=stdout,
                stderr=stderr,
            )
        require(group is not None)
        wait_until(group, deadline, lambda: (output / "ready").exists())
        require((output / "ready").read_bytes() == b"READY\n")
        writer = os.open(output / "stdin", os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        marker(output / "start")
        if case not in ("extra", "adhoc"):
            wait_until(group, deadline, lambda: "V1 HELD" in lines_from(output / "stdout"))
        if case == "current":
            require(os.write(writer, b"CURRENT\nRETIRE\n") == 15)
        elif case == "invalid":
            require(os.write(writer, b"INVALID\n") == 8)
        elif case == "overlong":
            require(os.write(writer, b"AAAAAAAA\n") == 9)
        elif case == "truncated":
            require(os.write(writer, b"CURR") == 4)
            closing_writer = writer
            writer = None
            os.close(closing_writer)
        elif case == "eof":
            closing_writer = writer
            writer = None
            os.close(closing_writer)
        elif case == "killed":
            require(group.observe_exit() is None)
            os.killpg(group.process.pid, signal.SIGKILL)
            group.signals.append(signal.SIGKILL)
        while terminal is None:
            terminal = group.observe_exit()
            require(time.monotonic() < deadline)
            if terminal is None:
                time.sleep(0.01)
    except BaseException as error:
        failure = type(error).__name__
    finally:
        # Mask cancellation only during real native ownership settlement.
        for number in handlers:
            try:
                signal.signal(number, signal.SIG_IGN)
            except (OSError, ValueError):
                failure = failure or "SignalMaskRefused"
        if writer is not None:
            closing_writer = writer
            writer = None
            try:
                os.close(closing_writer)
            except OSError:
                failure = failure or "InputCloseRefused"
        try:
            if group is not None:
                require(group.settle())
        except BaseException:
            failure = failure or "PhysicalRetirementRefused"
        finally:
            for number, previous in handlers.items():
                try:
                    signal.signal(number, previous)
                except (OSError, ValueError):
                    failure = failure or "SignalRestoreRefused"
    observations = lines_from(output / "stdout", complete=True)
    with (output / "stderr").open("rb") as stream:
        require(not stream.read(513))
    report = {
        "schema": 1,
        "case": case,
        "status": "error" if failure else "captured",
        "failure_class": failure,
        "observations": observations,
        "native_owner": group.receipt() if group is not None else None,
        "graceful_owner_retirement": False,
        "observations_supply_authority": False,
    }
    owner.exclusive_receipt(output / "observations.json", report)
    require(failure is None and group is not None and group.reaped)
    if case == "killed":
        require(group.process.returncode == -signal.SIGKILL)
        lines = observations
        require(lines == ["V1 HELD"])
        require(not any(line.startswith("V1 RETIRED ") for line in lines))
    else:
        expected = {
            "current": (0, ["V1 HELD", "V1 CURRENT 1", "V1 RETIRED command"]),
            "eof": (0, ["V1 HELD", "V1 RETIRED eof"]),
            "invalid": (64, ["V1 HELD", "V1 RETIRED input"]),
            "truncated": (64, ["V1 HELD", "V1 RETIRED input"]),
            "overlong": (64, ["V1 HELD", "V1 RETIRED input"]),
            "extra": (64, []),
            "adhoc": (69, ["V1 REFUSED principal", "V1 RETIRED unavailable"]),
        }
        status, expected_lines = expected[case]
        require(group.process.returncode == status and observations == expected_lines)
    owner.exclusive_receipt(
        output / "qualification.json",
        {
            "schema": 1,
            "case": case,
            "validated_case": True,
            "physical_child_retirement_observed": True,
            "graceful_owner_retirement": case not in ("extra", "killed"),
            "local_executing_principal_only": True,
            "service_lifecycle_authority": False,
        },
    )
    print("PASS native read-only owner case=" + case)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--owner", type=Path, required=True)
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--bridge", action="store_true")
    parser.add_argument("--extra", action="store_true")
    options = parser.parse_args()
    try:
        if options.bridge:
            bridge(options.app, options.owner, options.extra)
        else:
            require(not options.extra and options.case is not None)
            run(options.app, options.owner, options.case)
    except (OSError, ValueError, FixtureRefusal, owner.OwnedProcessError):
        print("Native owned-runtime reference fixture refused", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
