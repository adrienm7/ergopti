#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/atspi_fixture_app.py
#
# A GTK window whose single text field takes focus, for run_atspi_focus.sh.
# Usage: atspi_fixture_app.py <title> [password] [--lifetime-seconds N]
#        [--ready-file PATH] [--state-file PATH].
#
# With --ready-file, the file is created once the window manager made the window
# ACTIVE and its field holds the focus: the state the secure-field probe reads.
# A probe started after a fixed sleep could read a window not active yet.
#
# With --state-file, the file always holds "active" or "inactive", the window's
# own view: a window opened over this one makes it inactive in its own process,
# after the new window's ready file can already exist. Until then two frames
# report ACTIVE and the probe rightly answers inconclusive.

import argparse
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

parser = argparse.ArgumentParser(description="A bounded GTK accessibility fixture")
parser.add_argument("title", nargs="?", default="fixture")
parser.add_argument("mode", nargs="?", choices=["password"])
parser.add_argument("--lifetime-seconds", type=int, default=30)
parser.add_argument("--ready-file", type=Path)
parser.add_argument("--state-file", type=Path)
args = parser.parse_args()
if args.lifetime_seconds <= 0:
    parser.error("--lifetime-seconds must be positive")

window = Gtk.Window(title=args.title)
entry = Gtk.Entry()
if args.mode == "password":
    entry.set_visibility(False)
window.add(entry)


def announce_ready(*_):
    """Creates the ready file once the window is active and its field focused."""
    if not args.ready_file.exists() and window.is_active() and entry.has_focus():
        args.ready_file.touch()


def record_state(*_):
    """Replaces the state file whole, so a reader never sees a partial word."""
    staged = args.state_file.with_name(args.state_file.name + ".tmp")
    staged.write_text("active" if window.is_active() else "inactive")
    staged.replace(args.state_file)


if args.ready_file:
    window.connect("notify::is-active", announce_ready)
    entry.connect("notify::has-focus", announce_ready)
if args.state_file:
    record_state()
    window.connect("notify::is-active", record_state)


def end_of_life():
    """Quits, first recording the window as inactive: a window that is gone holds
    no activation, and a last « active » left behind would read as a window
    that never resigned."""
    if args.state_file:
        staged = args.state_file.with_name(args.state_file.name + ".tmp")
        staged.write_text("inactive")
        staged.replace(args.state_file)
    Gtk.main_quit()
    return False


window.show_all()
entry.grab_focus()
window.present()
GLib.timeout_add_seconds(args.lifetime_seconds, end_of_life)
Gtk.main()
