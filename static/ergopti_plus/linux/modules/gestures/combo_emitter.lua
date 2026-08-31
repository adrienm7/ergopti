--- modules/gestures/combo_emitter.lua

--- ==============================================================================
--- MODULE: Gesture Combos, Emitted Through uinput
--- DESCRIPTION:
--- Turns an X11-keysym combo string — `ctrl+Right`, `super+Up`, `alt+F4` — into
--- evdev keycodes and presses them on the device the daemon already owns.
---
--- WHY THIS REPLACES `xdotool key`:
--- Every gesture action ran through `os.execute("xdotool key …")`, which is X11
--- only. Under Wayland xdotool talks to nothing: the command succeeds, the
--- shell exits zero, and the gesture does nothing — the worst shape of failure,
--- because there is no error to find. uinput sits BELOW the display server, so
--- the same keystroke reaches X11, every Wayland compositor and a bare TTY
--- alike; it is the same reason the hotstring injector was moved off ydotool.
---
--- WHY A TABLE OF EIGHTEEN NAMES AND NOT ALL OF X11:
--- The combos are not arbitrary user input — they come from
--- `_shared/modules/actions/actions.toml` through the generated table, and the
--- whole catalogue uses eighteen distinct key names. Mapping those is bounded and
--- checkable; mapping "all of X11" would be a hundred entries written blind, most
--- of them never used, and no way to tell a wrong one from an unused one.
--- `tests/unit/modules/test_combo_emitter.lua` asserts that EVERY combo the
--- generated catalogue contains resolves, so the bound is enforced rather than
--- assumed — add an action with a new key name and the suite says so.
---
--- WHAT IT STILL CANNOT DO:
--- A keystroke is all uinput can express. "Switch to workspace 3" or "focus that
--- window" are not keystrokes, and no external process can perform them under
--- Wayland at all — there is no protocol for it. Those actions can only be a
--- combination the compositor already binds, and Hyprland, sway, i3, niri and
--- river ship none by default. That is a property of Wayland, not of this file.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local EvdevCodes = require("infra.evdev_codes")

local LOG = "gestures.combo_emitter"

-- The evdev value for a press and a release.
local PRESS = 1
local RELEASE = 0

-- X11 keysym name → evdev keycode, from include/uapi/linux/input-event-codes.h.
--
-- Only the names the shared action catalogue actually uses. Modifier names are
-- the lower-case ones xdotool accepts; the rest are X11 keysyms as the catalogue
-- spells them, which is why "Return" and not "Enter".
local KEYSYM_TO_CODE = {
	-- Modifiers. Left-hand variants, because a combo says which modifier it
	-- wants and not which side; the left one is the one every layout has.
	ctrl      = 29,  -- KEY_LEFTCTRL
	shift     = 42,  -- KEY_LEFTSHIFT
	alt       = 56,  -- KEY_LEFTALT
	super     = 125, -- KEY_LEFTMETA

	-- Navigation.
	Left      = 105, -- KEY_LEFT
	Right     = 106, -- KEY_RIGHT
	Up        = 103, -- KEY_UP
	Down      = 108, -- KEY_DOWN
	Home      = 102, -- KEY_HOME
	End       = 107, -- KEY_END

	-- Editing and control.
	Return    = 28,  -- KEY_ENTER
	Escape    = 1,   -- KEY_ESC
	Tab       = 15,  -- KEY_TAB
	Caps_Lock = 58,  -- KEY_CAPSLOCK
	BackSpace = 14,  -- KEY_BACKSPACE
	Delete    = 111, -- KEY_DELETE

	-- Function keys.
	F4        = 62,  -- KEY_F4
	F11       = 87,  -- KEY_F11

	-- The letters the catalogue uses: ctrl+v to paste, ctrl+t to open a tab and
	-- ctrl+w to close one. Added as the catalogue gained an emit_linux column for
	-- the two tab actions — the parity test caught them the same commit, which is
	-- what a table checked against the generated rows is for.
	t         = 20,  -- KEY_T
	v         = 47,  -- KEY_V
	w         = 17,  -- KEY_W
}

-- Which names are modifiers. A combo presses its modifiers first and releases
-- them last, so the order matters and cannot be read off the string alone.
local IS_MODIFIER = {
	ctrl = true, shift = true, alt = true, super = true,
}

M.KEYSYM_TO_CODE = KEYSYM_TO_CODE
M.IS_MODIFIER = IS_MODIFIER




-- =========================================
-- =========================================
-- ======= 1/ Reading a combo ==============
-- =========================================
-- =========================================

--- Splits a combo into the modifiers to hold and the keys to strike.
---
--- Pure, so the whole parse can be checked without a device — which is most of
--- what can go wrong here.
--- @param combo string e.g. "ctrl+shift+Tab"
--- @return table|nil { mods = {code…}, keys = {code…} }, string|nil unknown name
function M.parse(combo)
	if type(combo) ~= "string" or combo == "" then return nil, "empty combo" end

	local mods, keys = {}, {}
	for part in combo:gmatch("[^+%s]+") do
		local code = KEYSYM_TO_CODE[part]
		if not code then
			-- Named, not swallowed. An unmapped key name means the action
			-- catalogue grew and this table did not, and the symptom would
			-- otherwise be one gesture that quietly does nothing.
			return nil, part
		end
		if IS_MODIFIER[part] then
			mods[#mods + 1] = code
		else
			keys[#keys + 1] = code
		end
	end

	if #keys == 0 then return nil, "combo has no non-modifier key" end
	return { mods = mods, keys = keys }, nil
end




-- =========================================
-- =========================================
-- ======= 2/ Pressing it ==================
-- =========================================
-- =========================================

--- Presses a combo on the daemon's uinput device.
---
--- Modifiers down, keys down, keys up, modifiers up in reverse — the order a
--- physical hand produces, and the order every compositor expects. Releasing a
--- modifier before the key it modifies leaves the application seeing a bare
--- keystroke, which is the classic way a synthesised chord half-works.
--- @param combo string
--- @return boolean True when every event was written.
function M.press(combo)
	local parsed, unknown = M.parse(combo)
	if not parsed then
		Logger.error(LOG, "Cannot emit '%s': %s.", tostring(combo), tostring(unknown))
		return false
	end

	local ok_writer, Writer = pcall(require, "adapters.uinput_writer")
	if not ok_writer or type(Writer.emit) ~= "function" then
		Logger.error(LOG, "No uinput writer — '%s' cannot be emitted.", combo)
		return false
	end
	if type(Writer.is_open) == "function" and not Writer.is_open() then
		-- Loud rather than opened here: the daemon owns that device's lifetime,
		-- and a module that opened it on demand would race the one that closes it.
		Logger.error(LOG, "The uinput device is not open — '%s' was not emitted.", combo)
		return false
	end

	for _, code in ipairs(parsed.mods) do Writer.emit(code, PRESS) end
	for _, code in ipairs(parsed.keys) do Writer.emit(code, PRESS) end
	for i = #parsed.keys, 1, -1 do Writer.emit(parsed.keys[i], RELEASE) end
	for i = #parsed.mods, 1, -1 do Writer.emit(parsed.mods[i], RELEASE) end

	Logger.debug(LOG, "Emitted '%s' (%d modifier(s), %d key(s)).",
		combo, #parsed.mods, #parsed.keys)
	return true
end

return M
