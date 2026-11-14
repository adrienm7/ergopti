# desktop_focus (macOS)

STATUS: not implemented here, and deliberately so.

## Purpose

The code a driver installs into the desktop session itself so that it learns
which application has the keyboard focus. This folder exists on every driver
because Convention P says an absence must be a decision rather than an
oversight.

## What macOS uses instead

The system tells any process which application is frontmost:
`hs.application.frontmostApplication()` and the application watchers report it
through NSWorkspace, which the focus adapters in `platform/focus/` read. Nothing
has to run inside the window server, so there is nothing to install here.

## Why Linux needs one and this driver does not

A Wayland compositor does not expose the focused window to its clients. Linux
installs a GNOME Shell extension and a KWin script (`linux/platform/desktop_focus/`)
that run inside the compositor and report the focused application to the
daemon over the session bus.
