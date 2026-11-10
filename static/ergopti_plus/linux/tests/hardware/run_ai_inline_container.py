#!/usr/bin/env python3
# tests/hardware/run_ai_inline_container.py
"""AI inline auto-type into a real editor, and never into a password field.

Closes the "AI inline auto-type" check on a container (maintainer decision of
2026-11-10). The real daemon runs over the kernel model, with the AI enabled
on the API backend (tests/hardware/fake_llm_server.py, an OpenAI-compatible
API on loopback) and the trigger menu's inline switch on, as a user leaves it.

1. In mousepad on Xvfb, "bonjour" then a pause asks for a prediction; the
   finished prediction is typed through the daemon's virtual keyboard, with
   no Tab and no accepting key typed by the user. The editor's text is read
   back over AT-SPI.
2. In a GTK password field, the same typing and pause reach the field as typed
   and no prediction is requested or typed.

Exit 0 = every assertion held; 1 = a failure; 2 = no environment.
"""

import json
import os
import sys
import time

import container_session as cs

KEYBOARD = "Ergopti Proof Keyboard"
KEY_TAB, KEY_SPACE, KEY_SLASH = 15, 57, 53
LETTERS = {
    c: k
    for k, c in zip(
        [
            16,
            17,
            18,
            19,
            20,
            21,
            22,
            23,
            24,
            25,
            30,
            31,
            32,
            33,
            34,
            35,
            36,
            37,
            38,
            44,
            45,
            46,
            47,
            48,
            49,
            50,
        ],
        "qwertyuiopasdfghjklzxcvbnm",
    )
}
LETTERS[" "], LETTERS["/"] = KEY_SPACE, KEY_SLASH
REPLY = " que tout le monde va bien"
API_KEY = "container-proof-key"
PORT = 18000 + os.getpid() % 1000

PREPARE = r"""
assert(require("infra.llm_preferences").set_many({ ["llm.trigger.inline_autotype"] = true }),
	"the inline switch must reach canonical preferences")
"""


def type_text(session, text):
    for char in text:
        session.tap(KEYBOARD, LETTERS[char])


def requests(log):
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines() if line.strip()]


def proof():
    session = cs.Session("x11", [{"event": 90, "name": KEYBOARD, "kind": "keyboard"}])
    try:
        session.mount_devices()
        session.start_desktop()
        log, ready = session.root / "llm.log", session.root / "llm.ready"
        session.spawn(
            [
                sys.executable,
                str(cs.HERE / "fake_llm_server.py"),
                "--port",
                str(PORT),
                "--log",
                str(log),
                "--reply",
                REPLY,
                "--ready-file",
                str(ready),
            ]
        )
        if not cs.wait_for(ready.exists, 10):
            raise RuntimeError("ENVIRONMENT: the fake LLM API never started")
        session.env["ERGOPTI_LIVE_LLM_PORT"] = str(PORT)
        config = session.prepare(PREPARE)
        (config / "api_keys.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "active_id": "proof",
                    "entries": [
                        {
                            "id": "proof",
                            "provider": "openai_compat",
                            "label": "Proof",
                            "token": API_KEY,
                            "model": "proof-model",
                            "base_url": "http://127.0.0.1:%d/v1" % PORT,
                        }
                    ],
                }
            )
        )
        os.chmod(config / "api_keys.json", 0o600)
        session.start_daemon()
        cs.check(
            session.editor(session.root / "inline.txt"),
            "mousepad shows an empty document on AT-SPI",
        )
        time.sleep(2)

        # 1/ The editor.
        mark, before = session.mark(), len(requests(log))
        type_text(session, "bonjour")
        expected = "bonjour" + REPLY
        state = cs.wait_for(
            lambda: (lambda s: s if s[0] == expected else None)(session.editor_state()), 15
        )
        rows = session.since(mark)
        if not state:
            print("  editor holds: %r" % (session.editor_state()[0],))
        cs.check(
            len(requests(log)) > before, "the pause after the word asked the API for a prediction"
        )
        cs.check(
            state is not None, "the finished prediction was typed into mousepad: %r" % expected
        )
        cs.check(
            "Inline mode: typing the finished prediction" in session.log_text(),
            "the daemon typed it in inline mode",
        )
        cs.check(
            not any(row.startswith("K %d " % KEY_TAB) for row in rows), "no Tab left the daemon"
        )

        # 2/ A password field.
        session.spawn(
            [
                sys.executable,
                str(cs.HERE / "atspi_fixture_app.py"),
                "Proof password",
                "password",
                "--lifetime-seconds",
                "60",
            ]
        )
        cs.check(
            cs.wait_for(lambda: session.text_widget("password_text"), 15),
            "the password field is on AT-SPI",
        )
        time.sleep(1.5)
        mark, before = session.mark(), len(requests(log))
        typed = "secret"
        type_text(session, typed)
        time.sleep(4)
        text, _ = session.editor_state("password_text")
        cs.check(
            text is not None and len(text) == len(typed),
            "the password field holds only what was typed",
        )
        cs.check(
            len(requests(log)) == before, "no prediction was requested from the password field"
        )
        letters = [row for row in session.since(mark) if row.endswith(" 1")]
        cs.check(len(letters) == len(typed), "the daemon typed nothing beyond the user's own keys")
        editor, _ = session.editor_state()
        cs.check(editor == expected, "the editor is unchanged by the password-field typing")
    except cs.ProofFailure:
        session.dump_log()
        raise
    finally:
        session.stop()


if __name__ == "__main__":
    sys.exit(cs.run(proof))
