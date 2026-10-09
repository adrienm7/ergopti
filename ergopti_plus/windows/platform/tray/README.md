# tray (Windows)

STATUS: not implemented here, and deliberately so.

## Purpose

The mechanism a driver uses to put an icon in the system tray and hang a menu
off it. This folder exists on every driver because Convention P says an absence
must be a decision rather than an oversight — and on Windows the decision is
that there is nothing to put here.

## What Windows uses instead

AutoHotkey's built-in tray. `A_TrayMenu` is a live `Menu` object from the moment
the script starts, `TraySetIcon()` sets the icon, and `Add()` builds the rows.
The language ships the shell integration, so there is no protocol to speak and
no library to bind — a `platform/` seam would be a folder containing one call.

## Why Linux needs one and this driver does not

Linux has no equivalent. A tray icon there is a StatusNotifierItem — a D-Bus
object the process must HOST for its whole life, answering `GetLayout`,
`GetGroupProperties`, `Event` and `AboutToShow` — and the practical way to host
one is to bind `libayatana-appindicator` and build a `GtkMenu`. That is a
genuine OS mechanism with a genuine choice behind it, which is what `platform/`
is for.

See `linux/platform/tray/appindicator.lua`.
