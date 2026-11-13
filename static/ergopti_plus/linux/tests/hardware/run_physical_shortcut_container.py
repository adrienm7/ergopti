#!/usr/bin/env python3
# tests/hardware/run_physical_shortcut_container.py
"""Physical shortcut delivery (LIN-004) on the kernel model, delivery only.

The production getter `keyboard_shortcuts.physical_delivery_available` stays
false: it gates the editor too, and the Linux editor's physical capture is not
qualified. This proof's daemon process alone answers true, so the delivery path
behind the getter can be measured as LIN-004 asks, with physical slots written
in config.toml as the editor would save them:

1. A bound key (J, no modifier, bound to select_all) is suppressed exactly
   once: one Ctrl+A chord leaves the daemon and no J, also while the key is
   held with kernel autorepeat; the action reaches mousepad (typing then
   replaces the whole text).
2. No other owner also acts: a hotstring's last key (Z of "xz" -> MATCH) runs
   the slot and the hotstring never expands; a tap-hold key (Tab) keeps its
   tap-hold and the slot does not also run; under the navigation layer (Alt
   held) K keeps the layer's ArrowLeft and physical_alt_KeyK does not also run;
   the physical magic key (KeyQ) bound to a slot runs the slot and types no
   magic character.

Exit 0 = every assertion held; 1 = a failure; 2 = no environment.
"""

import subprocess
import sys
import time

import container_session as cs

KEYBOARD = "Ergopti Proof Keyboard"
KEY_TAB, KEY_Q, KEY_W, KEY_A, KEY_J, KEY_K = 15, 16, 17, 30, 36, 37
KEY_Z, KEY_X, KEY_B, KEY_C, KEY_LEFTALT = 44, 45, 48, 46, 56
KEY_LEFTCTRL, KEY_LEFT = 29, 105
SELECT_ALL = ["K 29 1", "K 30 1", "K 30 0", "K 29 0"]

PREPARE = r"""
local Paths = require("settings.engine.paths")
local fh = assert(io.open(Paths.config("config.toml"), "ab"))
fh:write('\n[hotstrings]\nmagic_key_source = "KeyQ"\n\n[shortcuts]\nenabled = true\n\n[shortcuts.keyboard]\n'
	.. 'physical_none_KeyJ = "select_all"\nphysical_none_KeyZ = "select_all"\nphysical_none_Tab = "select_all"\n'
	.. 'physical_alt_KeyK = "select_all"\nphysical_none_KeyQ = "select_all"\n')
fh:close()
"""

# The daemon, unchanged, with only the delivery getter answering true in its
# own process: the evidence LIN-004 asks for before the production getter may.
LAUNCH = (
    'require("modules.shortcuts.keyboard_shortcuts").physical_delivery_available = function() return true end; '
    'arg = {[0] = "ergopti_hotstrings.lua", "--verbose", "--config", "tests/e2e/fixtures/daemon_keys.toml"}; '
    'dofile("ergopti_hotstrings.lua")'
)


def start_daemon(session):
    session.daemon = subprocess.Popen(
        ["luajit", "-e", LAUNCH],
        cwd=cs.DRIVER,
        env=dict(session.env, **session.daemon_env),
        stdout=open(session.log, "w"),
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    ready = cs.wait_for(
        lambda: "Daemon ready" in session.log_text() or session.daemon.poll() is not None, 60
    )
    if session.daemon.poll() is not None or not ready:
        raise cs.ProofFailure("the daemon did not report itself ready")
    cs.check(
        cs.wait_for(lambda: session.grabbed(KEYBOARD), 10), "the daemon grabbed the model keyboard"
    )
    time.sleep(1.5)


def type_codes(session, codes):
    for code in codes:
        session.tap(KEYBOARD, code)


def rows_of(session, action):
    mark = session.mark()
    action()
    time.sleep(0.8)
    return session.since(mark)


def proof():
    session = cs.Session("x11", [{"event": 90, "name": KEYBOARD, "kind": "keyboard"}])
    try:
        session.mount_devices()
        session.start_desktop()
        session.prepare(PREPARE)
        cs.check(
            session.editor(session.root / "slots.txt"), "mousepad shows an empty document on AT-SPI"
        )
        start_daemon(session)

        # 1/ Suppressed exactly once, the action reaching the window.
        type_codes(session, (KEY_A, KEY_B, KEY_C))
        time.sleep(0.5)
        rows = rows_of(session, lambda: session.tap(KEYBOARD, KEY_J))
        cs.check(
            rows == SELECT_ALL,
            "the bound J sent one select_all chord and no J: " + " | ".join(rows),
        )
        session.tap(KEYBOARD, KEY_X)
        state = cs.wait_for(
            lambda: (lambda s: s if s[0] == "x" else None)(session.editor_state()), 5
        )
        cs.check(
            state is not None, "the action reached mousepad: the next key replaced the whole text"
        )

        def held():
            session.key(KEYBOARD, KEY_J, 1)
            time.sleep(0.3)
            for _ in range(4):
                session.key(KEYBOARD, KEY_J, 2)
                time.sleep(0.04)
            session.key(KEYBOARD, KEY_J, 0)

        rows = rows_of(session, held)
        cs.check(
            rows == SELECT_ALL,
            "a held J with autorepeat still runs once and leaks nothing: " + " | ".join(rows),
        )

        # 2/ No other owner also acts.
        type_codes(session, (KEY_A, KEY_B, KEY_X))
        rows = rows_of(session, lambda: session.tap(KEYBOARD, KEY_Z))
        cs.check(
            rows == SELECT_ALL, "the hotstring's last key ran the slot alone: " + " | ".join(rows)
        )
        session.tap(KEYBOARD, KEY_W)
        state = cs.wait_for(
            lambda: (lambda s: s if s[0] == "w" else None)(session.editor_state()), 5
        )
        cs.check(state is not None, "the hotstring xz never expanded (no MATCH in the editor)")

        rows = rows_of(session, lambda: session.tap(KEYBOARD, KEY_TAB, hold=0.05))
        cs.check(
            rows and "K 30 1" not in rows,
            "the tap-hold Tab kept its own tap and the slot did not also run: " + " | ".join(rows),
        )

        def layer_k():
            session.key(KEYBOARD, KEY_LEFTALT, 1)
            time.sleep(0.35)
            session.tap(KEYBOARD, KEY_K)
            session.key(KEYBOARD, KEY_LEFTALT, 0)

        rows = rows_of(session, layer_k)
        cs.check(
            rows == ["K %d 1" % KEY_LEFT, "K %d 0" % KEY_LEFT],
            "under the layer K kept its ArrowLeft and physical_alt_KeyK did not also run: "
            + " | ".join(rows),
        )

        rows = rows_of(session, lambda: session.tap(KEYBOARD, KEY_Q))
        cs.check(
            rows == SELECT_ALL,
            "the magic key bound to a slot ran the slot alone: " + " | ".join(rows),
        )
        text, _ = session.editor_state()
        cs.check(text is not None and "★" not in text, "no magic character was typed")
    except cs.ProofFailure:
        session.dump_log()
        raise
    finally:
        session.stop()


if __name__ == "__main__":
    sys.exit(cs.run(proof))
