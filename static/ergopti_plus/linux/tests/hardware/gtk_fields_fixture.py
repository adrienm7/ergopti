#!/usr/bin/env python3
# tests/hardware/gtk_fields_fixture.py

"""A GTK window of text fields a Lua flow drives, for run_gtk_fields_live.sh.

Usage: gtk_fields_fixture.py <directory> <title> <kind>...
Each kind is ``text`` (a Gtk.Entry) or ``password`` (an invisible one), in the
window's Tab order. The fixture publishes ``state.json`` in the directory:
``{"focused": index or null, "texts": [...], "cursor": [...]}``, rewritten
whole (temporary file, then rename) on every text, focus or caret change, so a
reader sees the previous document or the next, never half of one.

On SIGUSR1 it applies ``control.json``: ``{"texts": [...]}`` replaces the
fields' texts when present, then ``{"target": i, "start": s, "end": e}`` gives
field i the focus and selects [s, e) (end -1 selects to the end; start == end
places the caret). The window is presented first, so the window manager makes
it active again after another window took the focus.
"""

import json
import os
from pathlib import Path
import signal
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

LIFETIME_SECONDS = 300


def main():
    """Shows the window and serves control requests until killed."""
    directory, title, kinds = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
    if not kinds or any(kind not in ("text", "password") for kind in kinds):
        raise SystemExit("usage: gtk_fields_fixture.py <directory> <title> text|password...")
    window = Gtk.Window(title=title)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    entries = []
    for kind in kinds:
        entry = Gtk.Entry()
        entry.set_visibility(kind != "password")
        box.pack_start(entry, True, True, 0)
        entries.append(entry)
    window.add(box)

    def publish(*_):
        focused = [index for index, entry in enumerate(entries) if entry.is_focus()]
        document = {
            "focused": focused[0] if window.is_active() and focused else None,
            "texts": [entry.get_text() for entry in entries],
            "cursor": [entry.get_position() for entry in entries],
        }
        staged = directory / "state.json.tmp"
        staged.write_text(json.dumps(document))
        os.replace(staged, directory / "state.json")
        return False

    def control():
        request = json.loads((directory / "control.json").read_text())
        if "texts" in request:
            for entry, text in zip(entries, request["texts"]):
                entry.set_text(text)
        window.present()
        target = entries[request["target"]]
        target.grab_focus()
        target.select_region(request.get("start", 0), request.get("end", -1))
        publish()
        return True

    for entry in entries:
        entry.connect("changed", publish)
        entry.connect("notify::has-focus", publish)
        entry.connect("notify::cursor-position", publish)
    window.connect("notify::is-active", publish)
    window.show_all()
    publish()
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, control)
    GLib.timeout_add_seconds(LIFETIME_SECONDS, Gtk.main_quit)
    Gtk.main()


if __name__ == "__main__":
    main()
