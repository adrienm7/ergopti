#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/atspi_fixture_app.py
#
# A GTK window whose single text field takes focus, for run_atspi_focus.sh.
# Usage: atspi_fixture_app.py <title> [password] — exits after 30 seconds.

import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

window = Gtk.Window(title=sys.argv[1] if len(sys.argv) > 1 else "fixture")
entry = Gtk.Entry()
if len(sys.argv) > 2 and sys.argv[2] == "password":
    entry.set_visibility(False)
window.add(entry)
window.show_all()
entry.grab_focus()
window.present()
GLib.timeout_add(30000, Gtk.main_quit)
Gtk.main()
