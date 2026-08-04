--- infra/evdev_codes.lua

--- ==============================================================================
--- MODULE: evdev Key Codes (Linux)
--- DESCRIPTION:
--- The kernel keycodes this driver reasons about by identity rather than by the
--- character they produce: modifiers, and the control keys the domain wants
--- named.
---
--- WHY THIS EXISTS:
--- Capture used to scrape text, so the hook recognised keys by the STRING
--- `libinput` and `evtest` printed — "KEY_LEFTSHIFT", "KEY_BACKSPACE". Reading
--- the device directly means there is no string: the kernel reports a number.
--- Those numbers were already written down once, as file-locals inside a reader
--- loop nothing called, and would otherwise be written down a second time here.
---
--- FEATURES & RATIONALE:
--- 1. Identity, not layout. `_shared/data/keycodes/evdev.json` maps codes to the
---    characters a layout produces and is the single source for that. This file
---    is the disjoint question — which physical key is this — and the two must
---    not be conflated: a modifier has no character, and asking the layout table
---    about one is how a phantom typed character gets invented.
--- 2. Names come back out. The domain callbacks and the keylogger want
---    "backspace", not 14, and the heatmap wants the code. Both directions live
---    here so neither is re-derived at a call site.
--- 3. Values are from input-event-codes.h and are kernel ABI. They do not change
---    between architectures or distributions, which is why they can be constants
---    rather than a probe.
--- ==============================================================================

local M = {}




-- ==============================================
-- ==============================================
-- ======= 1/ Modifiers =========================
-- ==============================================
-- ==============================================

M.KEY_LEFTSHIFT  = 42
M.KEY_RIGHTSHIFT = 54
M.KEY_LEFTCTRL   = 29
M.KEY_RIGHTCTRL  = 97
M.KEY_LEFTALT    = 56
M.KEY_RIGHTALT   = 100   -- AltGr
M.KEY_LEFTMETA   = 125
M.KEY_RIGHTMETA  = 126
M.KEY_CAPSLOCK   = 58

--- Which modifier a code belongs to, or nil when it is not one.
--- Keyed by code so the hook answers "is this a modifier" in one lookup instead
--- of a chain of comparisons that has to be kept in sync in three places.
M.MODIFIER_OF = {
	[M.KEY_LEFTSHIFT]  = "shift",
	[M.KEY_RIGHTSHIFT] = "shift",
	[M.KEY_LEFTCTRL]   = "ctrl",
	[M.KEY_RIGHTCTRL]  = "ctrl",
	[M.KEY_LEFTALT]    = "alt",
	[M.KEY_RIGHTALT]   = "alt",
	[M.KEY_LEFTMETA]   = "meta",
	[M.KEY_RIGHTMETA]  = "meta",
}




-- ==============================================
-- ==============================================
-- ======= 2/ Named control keys ================
-- ==============================================
-- ==============================================

--- Codes named individually because something synthesises them rather than only
--- recognising them. The injector emits Backspace to erase a trigger, so it
--- needs the number, and a second literal 14 in that file is the duplication
--- this module exists to prevent.
M.KEY_BACKSPACE = 14
M.KEY_TAB       = 15
M.KEY_ENTER     = 28
M.KEY_ESC       = 1

--- Codes the domain wants by name. A key absent from this table and absent from
--- the layout produces nothing, which is correct: it is a key this driver has no
--- opinion about, and under a grab it is still re-emitted untouched.
M.CONTROL_NAME_OF = {
	[M.KEY_BACKSPACE] = "backspace",
	[M.KEY_TAB]       = "tab",
	[M.KEY_ENTER]     = "enter",
	[96]  = "enter",       -- keypad Enter, same meaning to the domain
	[M.KEY_ESC]       = "escape",
	[103] = "up",
	[108] = "down",
	[105] = "left",
	[106] = "right",
	[102] = "home",
	[107] = "end",
	[104] = "pageup",
	[109] = "pagedown",
	[110] = "insert",
	[111] = "delete",
	[59]  = "f1",
	[60]  = "f2",
	[61]  = "f3",
	[62]  = "f4",
	[63]  = "f5",
	[64]  = "f6",
	[65]  = "f7",
	[66]  = "f8",
	[67]  = "f9",
	[68]  = "f10",
	[87]  = "f11",
	[88]  = "f12",
}

--- The KEY_* spelling of a code, for log lines and for the physical-key callback
--- that used to receive one from the text parser. Built from the two tables
--- above rather than written a third time.
local _key_name_of = nil

--- Returns the KEY_* name for a code, or nil when this driver has no name for it.
--- @param code integer evdev keycode.
--- @return string|nil
function M.key_name(code)
	if not _key_name_of then
		_key_name_of = {}
		for c, modifier in pairs(M.MODIFIER_OF) do
			-- Recover the constant's own spelling: MODIFIER_OF collapses left and
			-- right into one word, and the physical-key callback wants them apart.
			_key_name_of[c] = "KEY_" .. modifier:upper()
		end
		_key_name_of[M.KEY_LEFTSHIFT]  = "KEY_LEFTSHIFT"
		_key_name_of[M.KEY_RIGHTSHIFT] = "KEY_RIGHTSHIFT"
		_key_name_of[M.KEY_LEFTCTRL]   = "KEY_LEFTCTRL"
		_key_name_of[M.KEY_RIGHTCTRL]  = "KEY_RIGHTCTRL"
		_key_name_of[M.KEY_LEFTALT]    = "KEY_LEFTALT"
		_key_name_of[M.KEY_RIGHTALT]   = "KEY_RIGHTALT"
		_key_name_of[M.KEY_LEFTMETA]   = "KEY_LEFTMETA"
		_key_name_of[M.KEY_RIGHTMETA]  = "KEY_RIGHTMETA"
		_key_name_of[M.KEY_CAPSLOCK]   = "KEY_CAPSLOCK"
		for c, name in pairs(M.CONTROL_NAME_OF) do
			if not _key_name_of[c] then _key_name_of[c] = "KEY_" .. name:upper() end
		end
	end
	return _key_name_of[code]
end

return M
