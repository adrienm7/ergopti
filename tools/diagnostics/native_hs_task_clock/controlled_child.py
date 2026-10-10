"""Finite controlled pipe peer; this is not a Karabiner worker."""

import json
import os
import selectors
import sys
import time


def main():
    path = sys.argv[1]
    started = time.monotonic_ns()
    events = []
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    selector = selectors.DefaultSelector()
    os.set_blocking(0, False)
    selector.register(0, selectors.EVENT_READ)
    outcome = "failed"
    try:
        if os.write(1, b"TASK_READY\n") != 11:
            return 1
        for sequence in (1, 2, 3):
            deadline = time.monotonic() + 6.75
            line = b""
            while b"\n" not in line:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    return 1
                fragment = os.read(0, 64)
                if not fragment or len(line) + len(fragment) > 32:
                    return 1
                line += fragment
            if line != ("TASK_PING %d\n" % sequence).encode("ascii"):
                return 1
            frame = ("TASK_ACK %d\n" % sequence).encode("ascii")
            if os.write(1, frame) != len(frame):
                return 1
            elapsed = time.monotonic_ns() - started
            if not 0 <= elapsed <= 45_000_000_000:
                return 1
            events.append(
                {
                    "seq": sequence,
                    "boundary": "controlled-child-ack-write",
                    "clock": "child-monotonic-relative",
                    "elapsed_ns": elapsed,
                }
            )
        deadline = time.monotonic() + 6.75
        if not selector.select(max(0, deadline - time.monotonic())):
            return 1
        if os.read(0, 64) != b"TASK_DONE\n":
            return 1
        outcome = "completed"
        return 0
    finally:
        # A final retained record also exposes incomplete child execution honestly.
        raw = json.dumps(
            {"schema": 1, "outcome": outcome, "events": events}, separators=(",", ":")
        ).encode("ascii")
        if len(raw) <= 2048:
            if os.write(descriptor, raw) != len(raw):
                raise RuntimeError("closed_child_receipt_write_refused")
        os.close(descriptor)
        selector.close()


if __name__ == "__main__":
    raise SystemExit(main())
