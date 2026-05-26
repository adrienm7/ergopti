--- drivers/_shared/lua/keycodes/qwerty_names.lua

--- ==============================================================================
--- MODULE: QWERTY Key Names (Shared)
--- DESCRIPTION:
--- Platform-neutral mapping from Carbon virtual keycode numbers to Karabiner
--- key_code names (USB HID QWERTY physical key names).
--- Shared across all Ergopti+ drivers (Hammerspoon, Linux, and future platforms).
---
--- FEATURES & RATIONALE:
--- 1. Layout-independent constant: keycode 31 is always the physical "O" position,
---    regardless of what character the current OS layout produces there.
--- 2. Single source of truth: extracted from lib/layout.lua so that any driver
---    needing to translate a resolved keycode back into a Karabiner-compatible
---    name reads from here, not from hs.keycodes.map (which reflects the current
---    input source and would loop back to the layout character).
--- 3. Platform-neutral: pure data table — no hs.* or OS API dependency.
--- ==============================================================================

local M = {}




-- =============================================
--- =============================================
-- ======= 1/ Keycode to QWERTY Name Map =======
--- =============================================
-- =============================================

--- Fixed mapping from Carbon virtual keycode numbers to Karabiner key_code
--- names (USB HID QWERTY physical key names).
--- This table is layout-independent: keycode 31 is always the physical "O"
--- position, regardless of what character the current layout produces there.
--- Used to translate a resolved keycode back into a Karabiner-compatible name.
M.KEYCODE_TO_QWERTY_NAME = {
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

return M
