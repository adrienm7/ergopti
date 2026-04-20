--- lib/layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Resolver
--- DESCRIPTION:
--- Translates between logical characters and Karabiner key_code names using
--- the OS keyboard layout currently active in macOS.
---
--- FEATURES & RATIONALE:
--- 1. Layout-aware: uses hs.keycodes.map to resolve which physical key produces
---    a given character on the current input source.
--- 2. Fixed QWERTY translation: keycode → Karabiner key_code is a layout-
---    independent constant (USB HID / Carbon virtual key mapping), so it is
---    stored inline and NOT read from hs.keycodes.map — otherwise the map's
---    remapped string keys would loop back to the layout character instead of
---    the physical QWERTY position.
--- 3. Shared: avoids duplicating the same lookup logic in every module that
---    needs to map a logical char to a physical key position.
--- 4. Graceful fallback: returns the char itself when hs.keycodes.map is
---    unavailable, which preserves QWERTY behaviour without crashing.
---
--- USAGE:
---   local Layout = require("lib.layout")
---   local key_code = Layout.key_code_for_char("c")   -- → "o" on Ergopti
---   local char     = Layout.char_for_key_code("o")   -- → "c" on Ergopti
--- ==============================================================================

local M = {}
local hs = hs




-- =====================================
-- =====================================
-- ======= 1/ Keycode Constants =======
-- =====================================
-- =====================================

--- Fixed mapping from Carbon virtual keycode numbers to Karabiner key_code
--- names (USB HID QWERTY physical key names).
--- This table is layout-independent: keycode 31 is always the physical "O"
--- position, regardless of what character the current layout produces there.
--- Used to translate a resolved keycode back into a Karabiner-compatible name.
local KEYCODE_TO_QWERTY_NAME = {
	[0]   = "a",
	[1]   = "s",
	[2]   = "d",
	[3]   = "f",
	[4]   = "h",
	[5]   = "g",
	[6]   = "z",
	[7]   = "x",
	[8]   = "c",
	[9]   = "v",
	[10]  = "non_us_backslash",
	[11]  = "b",
	[12]  = "q",
	[13]  = "w",
	[14]  = "e",
	[15]  = "r",
	[16]  = "y",
	[17]  = "t",
	[18]  = "1",
	[19]  = "2",
	[20]  = "3",
	[21]  = "4",
	[22]  = "6",
	[23]  = "5",
	[24]  = "equal_sign",
	[25]  = "9",
	[26]  = "7",
	[27]  = "hyphen",
	[28]  = "8",
	[29]  = "0",
	[30]  = "close_bracket",
	[31]  = "o",
	[32]  = "u",
	[33]  = "open_bracket",
	[34]  = "i",
	[35]  = "p",
	[37]  = "l",
	[38]  = "j",
	[39]  = "quote",
	[40]  = "k",
	[41]  = "semicolon",
	[42]  = "backslash",
	[43]  = "comma",
	[44]  = "slash",
	[45]  = "n",
	[46]  = "m",
	[47]  = "period",
	[48]  = "tab",
	[49]  = "spacebar",
	[50]  = "grave_accent_and_tilde",
	[51]  = "delete_or_backspace",
	[53]  = "escape",
	[55]  = "left_command",
	[56]  = "left_shift",
	[57]  = "caps_lock",
	[58]  = "left_option",
	[59]  = "left_control",
	[60]  = "right_shift",
	[61]  = "right_option",
	[62]  = "right_control",
	[63]  = "fn",
	[64]  = "f17",
	[65]  = "keypad_period",
	[67]  = "keypad_asterisk",
	[69]  = "keypad_plus",
	[71]  = "keypad_num_lock",
	[75]  = "keypad_slash",
	[76]  = "keypad_enter",
	[78]  = "keypad_hyphen",
	[79]  = "f18",
	[80]  = "f19",
	[81]  = "keypad_equal_sign",
	[82]  = "keypad_0",
	[83]  = "keypad_1",
	[84]  = "keypad_2",
	[85]  = "keypad_3",
	[86]  = "keypad_4",
	[87]  = "keypad_5",
	[88]  = "keypad_6",
	[89]  = "keypad_7",
	[91]  = "keypad_8",
	[92]  = "keypad_9",
	[96]  = "f5",
	[97]  = "f6",
	[98]  = "f7",
	[99]  = "f3",
	[100] = "f8",
	[101] = "f9",
	[103] = "f11",
	[105] = "f13",
	[106] = "f16",
	[107] = "f14",
	[109] = "f10",
	[111] = "f12",
	[113] = "f15",
	[118] = "f4",
	[120] = "f2",
	[122] = "f1",
	[123] = "left_arrow",
	[124] = "right_arrow",
	[125] = "down_arrow",
	[126] = "up_arrow",
}




-- ==============================
-- ==============================
-- ======= 2/ Core Helpers =======
-- ==============================
-- ==============================

--- Returns the current hs.keycodes.map snapshot, or nil on failure.
--- hs.keycodes.map is a bidirectional table:
---   map[keycode_number] → character produced on the CURRENT layout
---   map["a"], map["b"]… → keycode number of the key producing that character
--- The string keys are NOT QWERTY names for letters on a remapped layout;
--- they mirror the current layout. That is why Step 2 in key_code_for_char
--- does NOT iterate this map, and uses KEYCODE_TO_QWERTY_NAME instead.
--- @return table|nil
local function get_map()
	local ok, map = pcall(function() return hs.keycodes.map end)
	if ok and type(map) == "table" then return map end
	return nil
end


--- Returns the Karabiner key_code name (QWERTY physical key name) that produces
--- the given logical character on the current OS keyboard layout.
--- Example: on Ergopti, physical "O" produces "c", so key_code_for_char("c")
--- returns "o" — the value to use in Karabiner's key_code field.
--- Falls back to char itself when the layout cannot be read (assumes QWERTY).
--- @param char string Single character to resolve (e.g. "c").
--- @return string QWERTY key_code name (e.g. "o").
function M.key_code_for_char(char)
	local map = get_map()
	if not map then return char end

	-- Step 1: find the keycode number whose layout character matches char
	local target_keycode = nil
	for k, v in pairs(map) do
		if type(k) == "number" and tostring(v) == char then
			target_keycode = k
			break
		end
	end

	if not target_keycode then return char end

	-- Step 2: resolve keycode → QWERTY name via the fixed table
	-- (NOT via hs.keycodes.map, which would loop back to the layout character)
	return KEYCODE_TO_QWERTY_NAME[target_keycode] or char
end


--- Returns the character produced on the current layout by the given QWERTY key name.
--- Example: on Ergopti, physical "O" produces "c", so char_for_key_code("o")
--- returns "c".
--- Falls back to qwerty_name itself on error.
--- @param qwerty_name string QWERTY key name (e.g. "o").
--- @return string Character on current layout (e.g. "c").
function M.char_for_key_code(qwerty_name)
	local map = get_map()
	if not map then return qwerty_name end

	-- Find the keycode number whose QWERTY name matches the input
	local target_keycode = nil
	for kc, name in pairs(KEYCODE_TO_QWERTY_NAME) do
		if name == qwerty_name then
			target_keycode = kc
			break
		end
	end

	if not target_keycode then return qwerty_name end

	local char = map[target_keycode]
	if char then return tostring(char) end

	return qwerty_name
end

return M
