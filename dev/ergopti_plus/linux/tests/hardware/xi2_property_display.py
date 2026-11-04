"""Private non-input experiment leader; run only inside the pinned family owner."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


assert len(sys.argv) == 4, "owned evidence directory, executable and Xvfb required"
BASE = Path(sys.argv[1]).resolve(strict=True)
EXECUTABLE = Path(sys.argv[2]).resolve(strict=True)
XVFB = str(Path(sys.argv[3]).resolve(strict=True))


def main():
    executable = EXECUTABLE
    leader = None
    server_pidfd = None
    reader, writer = os.pipe()
    selector = selectors.DefaultSelector()
    rescue = 0
    termination_requested = False
    result = 1
    display_bytes = b""
    receipt = {"native": "UNRUN", "owned_display": "UNRUN"}
    try:
        controlled = subprocess.run(
            [str(executable), "--controlled"], capture_output=True, timeout=5, check=False
        )
        (BASE / "controlled.stdout").write_bytes(controlled.stdout)
        (BASE / "controlled.stderr").write_bytes(controlled.stderr)
        receipt["controlled_exit"] = controlled.returncode
        assert controlled.returncode == 0
        controlled_facts = json.loads(controlled.stdout)
        assert controlled_facts == {"controlled_passed": 16, "native_fetch": 0, "native_free": 0}
        receipt["controlled"] = controlled_facts
        with (
            (BASE / "xvfb.stdout").open("wb") as stdout,
            (BASE / "xvfb.stderr").open("wb") as stderr,
        ):
            leader = subprocess.Popen(
                [XVFB, "-displayfd", str(writer), "-screen", "0", "800x600x24", "-nolisten", "tcp"],
                stdout=stdout,
                stderr=stderr,
                pass_fds=(writer,),
            )
            server_pidfd = os.pidfd_open(leader.pid)
        os.close(writer)
        writer = None
        selector.register(reader, selectors.EVENT_READ)
        deadline = time.monotonic() + 10
        while b"\n" not in display_bytes:
            assert leader.poll() is None, "owned Xvfb exited before display receipt"
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("owned Xvfb display receipt deadline")
            if selector.select(min(remaining, 0.1)):
                block = os.read(reader, 32)
                assert block, "owned Xvfb closed its display receipt"
                display_bytes += block
                assert len(display_bytes) <= 16, "oversized owned display receipt"
        assert display_bytes.endswith(b"\n") and display_bytes[:-1].isdigit()
        assert len(display_bytes[:-1]) <= 5
        display = ":" + display_bytes[:-1].decode("ascii")
        assert leader.poll() is None, "owned Xvfb exited before native connection"
        completed = subprocess.run(
            [str(executable), display, str(leader.pid)], capture_output=True, timeout=5, check=False
        )
        (BASE / "native.stdout").write_bytes(completed.stdout)
        (BASE / "native.stderr").write_bytes(completed.stderr)
        receipt["native_exit"] = completed.returncode
        lines = completed.stdout.splitlines()
        assert len(lines) == 1, "native oracle must return one bounded receipt"
        assert len(lines[0]) <= 4096
        facts = json.loads(lines[0])
        receipt["native"] = facts
        assert leader.poll() is None, "owned Xvfb exited before native completion"
        assert completed.returncode == 0, "native property-cookie oracle refused"
        assert facts["server_peer_pid"] == leader.pid
        assert facts["server_peer_uid"] == os.getuid()
        assert facts["stage"] == 7
        assert facts["opened"] == facts["closed_calls"] == 1
        assert facts["close_status"] == 0
        assert facts["fetched"] == facts["freed"] == facts["published"] == 3
        assert facts["xerrors"] == facts["input_injections"] == 0
        assert facts["native_epoch_claim"] is False
        result = 0
    except BaseException as error:
        receipt["failure_type"] = type(error).__name__
    finally:
        selector.close()
        os.close(reader)
        if writer is not None:
            os.close(writer)
        if leader is not None:
            if leader.poll() is None:
                try:
                    if server_pidfd is None:
                        raise RuntimeError("owned server pidfd acquisition refused")
                    signal.pidfd_send_signal(server_pidfd, signal.SIGTERM)
                    termination_requested = True
                except (OSError, RuntimeError):
                    result = 1
                    receipt["termination_refused"] = True
            else:
                receipt["premature_xvfb_exit"] = True
                result = 1
            try:
                receipt["xvfb_exit"] = leader.wait(timeout=3)
            except subprocess.TimeoutExpired:
                rescue += 1
                if server_pidfd is not None:
                    signal.pidfd_send_signal(server_pidfd, signal.SIGKILL)
                else:
                    # Retained original Popen child only; never an imported PID.
                    leader.kill()
                receipt["xvfb_exit"] = leader.wait(timeout=3)
            receipt["owned_display"] = "REAPED"
            receipt["termination_requested"] = termination_requested
            if not termination_requested or receipt["xvfb_exit"] not in (0, -signal.SIGTERM):
                result = 1
        if server_pidfd is not None:
            os.close(server_pidfd)
            receipt["server_pidfd_closed"] = True
        receipt["rescue"] = rescue
        receipt["scope"] = "property invalidation only; no Lua Probe or native source grant"
        if rescue:
            result = 1
        (BASE / "display-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return result


if __name__ == "__main__":
    sys.exit(main())
