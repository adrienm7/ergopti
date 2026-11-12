--- tests/hardware/run_xkb_group_name_identity.lua

--- ==============================================================================
--- MODULE: A Non-ASCII Layout Name Keeps Keystroke Typing On X11
--- DESCRIPTION:
--- Run by run_xkb_group_name_identity.py against an owned Xvfb that holds a
--- layout named « Français — bépo ». xkbcomp prints that name with
--- sign-extended octal escapes, so the server's keymap and its printed copy
--- differ in the name alone; the source probe's identity check must still
--- accept the keymap, or the daemon refuses every key it is asked to type
--- (native-keymap-unacknowledged), as it did for Bépo and the shipped
--- « Français — Ergopti » files.
--- ==============================================================================

package.path = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;" .. package.path

local handle = assert(io.popen("xkbcomp -xkb \"$DISPLAY\" - 2>/dev/null", "r"))
local printed = handle:read("*a")
handle:close()
-- Control: the server really holds the name xkbcomp cannot print back.
assert(printed:find("\\037777777", 1, true), "the fixture layout name is not the corrupted one")

local KeyboardLayout = require("adapters.keyboard_layout")
assert(KeyboardLayout.refresh(), "the keymap of a layout with a non-ASCII name was refused")
local generation, reason = require("adapters.xkb_capture").source_generation()
assert(generation ~= nil, "the desktop source is not acknowledged: " .. tostring(reason))
print("a non-ASCII layout name keeps keystroke typing on X11")
