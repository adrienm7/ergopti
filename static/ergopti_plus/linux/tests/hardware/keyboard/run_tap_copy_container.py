#!/usr/bin/env python3
# tests/hardware/keyboard/run_tap_copy_container.py
"""The tap-hold copy check on Wayland and on X11 without xclip, end to end.

Closes the "Tap-hold copy check on Wayland" check on a container (maintainer
decision of 2026-11-10). The real daemon runs over the kernel model with the
shipped tap-hold preset, whose left Shift tapped is copy:

1. sway headless (wlroots, with data-control) and mousepad on Wayland: a
   copy with text selected sends Ctrl+C once, the daemon's `wl-paste --watch`
   counter moves, the log says it was verified, and nothing is retried or
   warned; the clipboard holds the text. A copy with nothing selected is sent
   once more, then warned about exactly once.
2. mutter headless (GNOME's compositor, without data-control): the watch ends
   at once, the log says so, and a copy is sent once and left unchecked.
3. X11 (Xvfb, openbox, mousepad) with xclip hidden: the same copy is checked
   through libX11's selection timestamp instead, verified without a retry.

Exit 0 = every assertion held; 1 = a failure; 2 = no environment.
"""

import shutil
import subprocess
import sys
import time

import container_session as cs

KEYBOARD = "Ergopti Proof Keyboard"
KEY_LEFTCTRL, KEY_A, KEY_C, KEY_END, KEY_LEFTSHIFT = 29, 30, 46, 107, 42
TEXT = "alpha beta"
VERIFIED = "Tap-hold copy from tap_hold__left_shift verified"
RETRIED = "reached the clipboard only when sent again"
NEVER = "never reached the clipboard"
UNCHECKED = "Tap-hold copies are not checked"
WATCH_ENDED = "wl-paste --watch ended"
WATCHING = "Watching the Wayland clipboard for the tap-hold copy check."
# Each check waits copy_verify_ms (300 ms) per attempt; two attempts and margin.
SETTLE_S = 1.5


def copies(rows):
    """How many Ctrl+C chords the daemon wrote."""
    count, ctrl = 0, False
    for row in rows:
        _, code, value = row.split()
        if int(code) == KEY_LEFTCTRL:
            ctrl = value != "0"
        elif int(code) == KEY_C and value == "1" and ctrl:
            count += 1
    return count


def clipboard(session):
    """The Wayland clipboard's text, read with wl-paste like any client."""
    result = subprocess.run(
        ["wl-paste", "-n"], env=session.env, capture_output=True, text=True, timeout=5
    )
    return result.stdout if result.returncode == 0 else None


def start(kind, hide=()):
    session = cs.Session(kind, [{"event": 90, "name": KEYBOARD, "kind": "keyboard"}])
    session.mount_devices()
    for name in hide:
        session.hide_command(name)
    session.start_desktop()
    session.prepare()
    return session


def select_all(session):
    session.key(KEYBOARD, KEY_LEFTCTRL, 1)
    session.tap(KEYBOARD, KEY_A)
    session.key(KEYBOARD, KEY_LEFTCTRL, 0)
    time.sleep(0.3)


def tap_copy(session):
    mark, log_mark = session.mark(), len(session.log_text())
    session.tap(KEYBOARD, KEY_LEFTSHIFT, hold=0.08)
    time.sleep(SETTLE_S)
    return session.since(mark), session.log_text()[log_mark:]


def checked_copy(session, label):
    """A copy with text selected: verified once, never retried or warned."""
    cs.check(
        session.editor(session.root / "copy.txt", TEXT) is not None,
        label + ": mousepad shows its text",
    )
    session.start_daemon()
    select_all(session)
    rows, log = tap_copy(session)
    cs.check(copies(rows) == 1, label + ": the Shift tap sent Ctrl+C once: " + " | ".join(rows))
    cs.check(VERIFIED in log, label + ": the log says the copy was verified")
    cs.check(RETRIED not in log and NEVER not in log, label + ": no retry and no warning")
    return rows, log


def proof_sway():
    for tool in ("wl-copy", "wl-paste"):
        if not shutil.which(tool):
            raise SystemExit("ENVIRONMENT: " + tool + " is missing")
    session = start("sway")
    try:
        subprocess.run(["wl-copy", "--clear"], env=session.env, check=False)
        checked_copy(session, "sway")
        cs.check(
            WATCHING in session.log_text(),
            "sway: the daemon watches the clipboard with wl-paste --watch",
        )
        cs.check(
            cs.wait_for(lambda: clipboard(session) == TEXT, 3),
            "sway: the clipboard holds the selected text",
        )
        session.tap(KEYBOARD, KEY_END)
        time.sleep(0.3)
        rows, log = tap_copy(session)
        cs.check(
            copies(rows) == 2,
            "sway: with nothing selected the copy is sent once more: " + " | ".join(rows),
        )
        cs.check(log.count(NEVER) == 1, "sway: the empty copy is warned about exactly once")
        cs.check(VERIFIED not in log, "sway: the empty copy is not reported as verified")
    except cs.ProofFailure:
        session.dump_log()
        raise
    finally:
        session.stop()


def proof_mutter():
    session = start("mutter")
    try:
        session.start_daemon()
        cs.check(
            cs.wait_for(lambda: WATCH_ENDED in session.log_text(), 5),
            "mutter: the log says wl-paste --watch ended (no data-control)",
        )
        rows, log = tap_copy(session)
        cs.check(
            copies(rows) == 1,
            "mutter: the Shift tap sent Ctrl+C once, no retry: " + " | ".join(rows),
        )
        cs.check(UNCHECKED in session.log_text(), "mutter: the log says the copy goes unchecked")
        cs.check(session.log_text().count(UNCHECKED) == 1, "mutter: said once, not at every copy")
        rows, log = tap_copy(session)
        cs.check(
            copies(rows) == 1 and UNCHECKED not in log,
            "mutter: a second copy is sent, unchecked, unsaid",
        )
        cs.check(NEVER not in session.log_text(), "mutter: an unchecked copy is never warned about")
    except cs.ProofFailure:
        session.dump_log()
        raise
    finally:
        session.stop()


def proof_x11_without_xclip():
    session = start("x11", hide=("xclip",))
    try:
        cs.check(
            subprocess.run(
                ["sh", "-c", "command -v xclip"], env=session.env, capture_output=True
            ).returncode
            != 0,
            "x11: xclip is absent from the session",
        )
        checked_copy(session, "x11 without xclip")
    except cs.ProofFailure:
        session.dump_log()
        raise
    finally:
        session.stop()


def proof():
    proof_sway()
    proof_mutter()
    proof_x11_without_xclip()


if __name__ == "__main__":
    sys.exit(cs.run(proof))
