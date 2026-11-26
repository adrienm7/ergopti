#!/usr/bin/env python3
# tests/hardware/run_nav_pointer_container.py
"""The navigation layer's mouse buttons, repeat count and wheel, end to end.

Closes three "To confirm on Linux" checks on a container (maintainer decision
of 2026-11-10): the real daemon runs over the kernel model with a keyboard and
a mouse, the recommended layer plus `MouseMiddle = "escape"` in layers.toml,
and its output reaches mousepad on Xvfb through XTest, read back over AT-SPI.

1. Mouse buttons: under the layer, the middle button types Escape and never
   clicks. A leaked click would paste the PRIMARY selection, which holds a
   marker, into the editor; the daemon's output must carry Escape and no
   BTN_MIDDLE, and the editor text must stay as it was.
2. Repeat count: `3` then `arrow_up` (KeyS on the recommended layer) moves the
   caret up three lines in the editor.
3. Wheel: under the layer a notch up is the volume-up key and never scrolls
   (no REL_WHEEL leaves the daemon); out of the layer the mouse is not grabbed
   and its notch reaches the desktop directly.

Regression (2026-11-10): once the layer had given a mouse back, the next device
watchdog tick judged the mouse's custody by its renumbered input generation,
refused the source cohort and stopped the keyboard hook, so the daemon exited
seconds after the first use of a mouse binding. The proof waits for a watchdog
tick after each release and requires the daemon to still hold the keyboard.

Exit 0 = every assertion held; 1 = a failure; 2 = no environment.
"""

import subprocess
import sys
import time

import container_session as cs

KEYBOARD, MOUSE = "Ergopti Proof Keyboard", "Ergopti Proof Mouse"
KEY_ESC, KEY_3, KEY_S, KEY_LEFTALT, KEY_LEFTCTRL, KEY_END = 1, 4, 31, 56, 29, 107
KEY_UP, KEY_VOLUMEUP, KEY_VOLUMEDOWN = 103, 115, 114
BTN_MIDDLE, REL_WHEEL, REL_WHEEL_HI_RES = 0x112, 8, 11
LINES = "one\ntwo\nthree\nfour\nfive"
MARKER = "LEAKED-PRIMARY"

LAYER_LINE = '"MouseMiddle" = "escape"\n'
PREPARE = (
    "local LINE = %s\n" % repr(LAYER_LINE)
    + r"""
local Paths = require("settings.engine.paths")
local path = Paths.config("layers.toml")
local fh = assert(io.open(path, "rb")); local text = fh:read("*a"); fh:close()
local section = "[layers.nav.linux]\n"
local at = assert(text:find(section, 1, true), "the recommended layer has a Linux table")
text = text:sub(1, at + #section - 1) .. LINE .. text:sub(at + #section)
fh = assert(io.open(path, "wb")); fh:write(text); fh:close()
"""
)


def hold_layer(session):
    session.key(KEYBOARD, KEY_LEFTALT, 1)
    time.sleep(0.35)


def release_layer(session):
    session.key(KEYBOARD, KEY_LEFTALT, 0)
    time.sleep(0.3)


# The device watchdog runs every DEVICE_CHECK_TICKS (8) periodic ticks of
# 250 ms: waiting longer than that lets at least one run see the given-back mouse.
WATCHDOG_WAIT_S = 2.5


def survives_watchdog(session, when):
    time.sleep(WATCHDOG_WAIT_S)
    cs.check(
        session.alive(),
        "(nav-pointer-custody) the daemon still holds the keyboard after a device watchdog tick "
        + when,
    )


def line_of(text, caret):
    return text[:caret].count("\n") + 1


def proof():
    session = cs.Session(
        "x11",
        [
            {"event": 90, "name": KEYBOARD, "kind": "keyboard"},
            {"event": 91, "name": MOUSE, "kind": "mouse"},
        ],
    )
    try:
        session.mount_devices()
        session.start_desktop()
        session.prepare(PREPARE)
        cs.check(
            session.editor(session.root / "notes.txt", LINES) is not None,
            "mousepad shows its text on AT-SPI",
        )
        session.start_daemon()

        # The caret to the last line, typed through the daemon like any key.
        session.key(KEYBOARD, KEY_LEFTCTRL, 1)
        session.tap(KEYBOARD, KEY_END)
        session.key(KEYBOARD, KEY_LEFTCTRL, 0)
        state = cs.wait_for(
            lambda: (lambda s: s if s[0] == LINES and line_of(*s) == 5 else None)(
                session.editor_state()
            ),
            5,
        )
        cs.check(state is not None, "Ctrl+End put the caret on line 5 through the grab")

        # 1/ The middle button under the layer.
        subprocess.run(
            ["xclip", "-selection", "primary"], input=MARKER.encode(), env=session.env, check=True
        )
        mark = session.mark()
        hold_layer(session)
        cs.check(cs.wait_for(lambda: session.grabbed(MOUSE), 3), "the held layer takes the mouse")
        session.physical(MOUSE, [(cs.EV_KEY, BTN_MIDDLE, 1)])
        time.sleep(0.1)
        session.physical(MOUSE, [(cs.EV_KEY, BTN_MIDDLE, 0)])
        time.sleep(0.2)
        release_layer(session)
        rows = session.since(mark)
        cs.check(
            "K %d 1" % KEY_ESC in rows and "K %d 0" % KEY_ESC in rows,
            "the middle button under the layer typed Escape: " + " | ".join(rows),
        )
        cs.check(
            not any(row.startswith("K %d " % BTN_MIDDLE) for row in rows),
            "the middle button itself never left the daemon",
        )
        time.sleep(0.5)
        text, caret = session.editor_state()
        cs.check(
            text == LINES and MARKER not in text,
            "the editor received no middle click (PRIMARY not pasted)",
        )
        cs.check(
            cs.wait_for(lambda: not session.grabbed(MOUSE), 3),
            "the mouse goes back once the layer ends",
        )
        survives_watchdog(session, "with the mouse given back")

        # 2/ The repeat count.
        mark = session.mark()
        hold_layer(session)
        session.tap(KEYBOARD, KEY_3)
        session.tap(KEYBOARD, KEY_S)
        release_layer(session)
        rows = session.since(mark)
        cs.check(
            rows.count("K %d 1" % KEY_UP) == 3,
            "`3` then arrow_up sent ArrowUp three times: " + " | ".join(rows),
        )
        cs.check(
            not any(
                row.startswith("K %d " % KEY_3) or row.startswith("K %d " % KEY_S) for row in rows
            ),
            "neither the count key nor the action key was typed",
        )
        state = cs.wait_for(
            lambda: (lambda s: s if s[1] is not None and line_of(*s) == 2 else None)(
                session.editor_state()
            ),
            5,
        )
        cs.check(
            state is not None and state[0] == LINES, "the editor caret moved from line 5 to line 2"
        )
        survives_watchdog(session, "after the repeat count")

        # 3/ The wheel under the layer, then outside it.
        mark = session.mark()
        hold_layer(session)
        cs.check(
            cs.wait_for(lambda: session.grabbed(MOUSE), 3),
            "the held layer takes the mouse for its wheel",
        )
        session.physical(MOUSE, [(cs.EV_REL, REL_WHEEL, 1), (cs.EV_REL, REL_WHEEL_HI_RES, 120)])
        time.sleep(0.15)
        session.physical(MOUSE, [(cs.EV_REL, REL_WHEEL, -1), (cs.EV_REL, REL_WHEEL_HI_RES, -120)])
        time.sleep(0.15)
        release_layer(session)
        rows = session.since(mark)
        cs.check(
            "K %d 1" % KEY_VOLUMEUP in rows and "K %d 1" % KEY_VOLUMEDOWN in rows,
            "the wheel under the layer is the volume: " + " | ".join(rows),
        )
        cs.check(
            not any(
                row.startswith("R %d " % REL_WHEEL) or row.startswith("R %d " % REL_WHEEL_HI_RES)
                for row in rows
            ),
            "no notch scrolled while the layer held the wheel",
        )
        cs.check(not session.grabbed(MOUSE), "the mouse is not grabbed outside the layer")
        survives_watchdog(session, "after the wheel bindings")
        mark = session.mark()
        session.physical(MOUSE, [(cs.EV_REL, REL_WHEEL, 1)])
        time.sleep(0.3)
        cs.check(
            session.since(mark) == [],
            "outside the layer the notch goes straight to the desktop, untouched",
        )
        text, _ = session.editor_state()
        cs.check(text == LINES, "the editor text is unchanged at the end")
        held = [row for row in session.output() if row.endswith(" 1")]
        released = [row for row in session.output() if row.endswith(" 0")]
        cs.check(len(held) == len(released), "every key the daemon pressed was released")
    except cs.ProofFailure:
        session.dump_log()
        raise
    finally:
        session.stop()


if __name__ == "__main__":
    sys.exit(cs.run(proof))
