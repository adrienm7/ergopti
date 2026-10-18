#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/atspi_fixture_app.py
#
# A GTK window whose single text field takes focus, for run_atspi_focus.sh.
# Usage: atspi_fixture_app.py <title> [password] [--lifetime-seconds N].

import argparse

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

parser = argparse.ArgumentParser(description="A bounded GTK accessibility fixture")
parser.add_argument("title", nargs="?", default="fixture")
parser.add_argument("mode", nargs="?", choices=["password"])
parser.add_argument("--lifetime-seconds", type=int, default=30)
args = parser.parse_args()
if args.lifetime_seconds <= 0:
    parser.error("--lifetime-seconds must be positive")

window = Gtk.Window(title=args.title)
entry = Gtk.Entry()
if args.mode == "password":
    entry.set_visibility(False)
window.add(entry)
window.show_all()
entry.grab_focus()
window.present()
GLib.timeout_add_seconds(args.lifetime_seconds, Gtk.main_quit)
Gtk.main()
