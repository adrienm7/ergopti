# native (Linux)

STATUS: not implemented here, and deliberately so.

## Purpose

Compiled code a driver ships for a low-level input duty its scripting runtime
cannot hold on its own. This folder exists on every driver because Convention P
says an absence must be a decision rather than an oversight.

## What Linux uses instead

The daemon owns the keyboard itself: it grabs the evdev device and writes its
output through uinput (`platform/input/`), both through LuaJIT's FFI. No event
reaches another program before the daemon has decided on it, so there is no hook
to delegate to a separate binary.

## Why Windows needs one and this driver does not

AutoHotkey cannot own a low-level keyboard hook atomically while an LLM
prediction is being navigated. Windows ships a small C library
(`windows/platform/native/`) whose dedicated thread owns `WH_KEYBOARD_LL` and
runs that state machine without calling back into AutoHotkey.
