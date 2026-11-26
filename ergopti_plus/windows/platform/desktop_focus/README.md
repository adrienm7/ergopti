# desktop_focus (Windows)

STATUS: not implemented here, and deliberately so.

## Purpose

The code a driver installs into the desktop session itself so that it learns
which application has the keyboard focus. This folder exists on every driver
because Convention P says an absence must be a decision rather than an
oversight.

## What Windows uses instead

Win32 reports the foreground window to any process: the focus adapters in
`platform/focus/` read it with the window built-ins and an out-of-context
WinEvent hook (`SetWinEventHook`). Nothing has to run inside the shell, so there
is nothing to install here.

## Why Linux needs one and this driver does not

A Wayland compositor does not expose the focused window to its clients. Linux
installs a GNOME Shell extension and a KWin script (`linux/platform/desktop_focus/`)
that run inside the compositor and report the focused application to the
daemon over the session bus.
