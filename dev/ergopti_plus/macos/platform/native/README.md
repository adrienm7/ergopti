# native (macOS)

STATUS: not implemented here, and deliberately so.

## Purpose

Compiled code a driver ships for a low-level input duty its scripting runtime
cannot hold on its own. This folder exists on every driver because Convention P
says an absence must be a decision rather than an oversight.

## What macOS uses instead

Hammerspoon's `hs.eventtap` installs a Quartz event tap and runs the keyDown
callback synchronously in Lua, so the driver owns, suppresses and replays the
navigation keys it needs without a separate binary.

## Why Windows needs one and this driver does not

AutoHotkey cannot own a low-level keyboard hook atomically while an LLM
prediction is being navigated. Windows ships a small C library
(`windows/platform/native/`) whose dedicated thread owns `WH_KEYBOARD_LL` and
runs that state machine without calling back into AutoHotkey.
