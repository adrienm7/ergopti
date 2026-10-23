--- modules/keymap/layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Resolver
--- DESCRIPTION:
--- Translates between logical characters and Karabiner key_code names using
--- the OS keyboard layout currently active in macOS.
---
--- FEATURES & RATIONALE:
--- 1. Layout-aware: uses hs.keycodes.map to resolve which physical key produces
---    a given character on the current input source.
--- 2. HID translation: ordinary Carbon positions are fixed; the ISO pair
---    follows the virtual keyboard product the name is sent through
---    (virtual_keyboard_product), never the layout's keycode convention, which
---    the registry declares and keyboard_form() reads. Never
---    infer that convention from a variant's name or a different keyboard.
---    Character legends cannot translate HID names: they would loop back to
---    the layout character instead of the physical position.
--- 3. Shared: avoids duplicating the same lookup logic in every module that
---    needs to map a logical char to a physical key position.
--- 4. Graceful fallback: returns the char itself when hs.keycodes.map is
---    unavailable, which preserves QWERTY behaviour without crashing.
---
--- USAGE:
---   local Layout = require("modules.keymap.layout")
---   local key_code = Layout.key_code_for_char("c")   -- → "o" on Ergopti
---   local char     = Layout.char_for_key_code("o")   -- → "c" on Ergopti
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("infra.logger")
local Manifest = require("infra.manifest_reader")

local LOG = "layout"





-- ====================================
-- ====================================
-- ======= 1/ Keycode Constants =======
-- ====================================
-- ====================================

--- The virtual keyboard product Ergopti deploys by default (karabiner.json
--- `virtual_hid_keyboard.keyboard_type_v2`) and the form every generated
--- Karabiner name is written for. An Apple ISO keyboard already reports the key
--- left of 1 as non_us_backslash (0x64) and the key left of Z as
--- grave_accent_and_tilde (0x35), the registry's `macos_iso` Karabiner names; the
--- ANSI product passes both through to keycodes 10 and 50, the ISO keycodes
--- macOS gives that keyboard natively. The ISO product swaps them once more, so
--- every key Karabiner passed through typed the other key's character (#99:
--- "Karabiner on ANSI gives ISO behaviour"). The product is therefore never the
--- layout's keycode convention; that convention only tells which keycode a
--- physical key arrives as.
---
--- The product is the user's choice (config.toml [layout] virtual_keyboard:
--- "auto", "iso" or "ansi", declared once in the shared features manifest).
--- "auto" resolves to the product below; an explicit choice is deployed as
--- written and is never replaced by anything read from the active layout.
M.AUTOMATIC_VIRTUAL_KEYBOARD_PRODUCT = "ansi"

local CHOICE_AUTOMATIC = "auto"

--- Resolves the user's virtual keyboard choice to the product to deploy.
--- @param choice string "auto", "iso" or "ansi".
--- @return string product "ansi" or "iso".
function M.virtual_keyboard_product(choice)
	if choice == "ansi" or choice == "iso" then return choice end
	if choice == CHOICE_AUTOMATIC then return M.AUTOMATIC_VIRTUAL_KEYBOARD_PRODUCT end
	error("the virtual keyboard choice must be auto, iso or ansi, got " .. tostring(choice), 2)
end

--- The product the shipped default choice resolves to, for callers that run
--- before the user's choice is registered.
--- @return string product "ansi" or "iso".
function M.default_virtual_keyboard_product()
	return M.virtual_keyboard_product(Manifest.default_for("layout.virtual_keyboard"))
end

--- The keycode convention a key arrives in once Karabiner delivered it through
--- the deployed product. The ANSI product passes the ISO pair through, so a key
--- keeps the convention of the keyboard layout; the ISO product swaps the pair,
--- so each of the two keys arrives with the other convention's keycode.
--- @param convention string The active layout's keycode convention, "ansi" or "iso".
--- @param product string The deployed virtual keyboard product, "ansi" or "iso".
--- @return string form "ansi" or "iso".
function M.arrival_form(convention, product)
	assert(convention == "ansi" or convention == "iso", "the layout keycode convention must be ansi or iso")
	assert(product == "ansi" or product == "iso", "the virtual keyboard product must be ansi or iso")
	if product == "ansi" then return convention end
	return convention == "ansi" and "iso" or "ansi"
end

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





-- ===============================
-- ===============================
-- ======= 2/ Core Helpers =======
-- ===============================
-- ===============================

--- Reads the active registry layout's declared virtual-keyboard convention.
--- An unregistered source keeps the existing ANSI policy; a known registry
--- layout without its declaration refuses rather than swapping physical keys.
--- @param snapshot table|nil LayoutRegistry snapshot, injectable for pure checks.
--- @return string form ansi | iso.
function M.keyboard_form(snapshot)
	if snapshot == nil then snapshot = require("modules.keymap.layout_registry").snapshot() end
	assert(type(snapshot) == "table" and type(snapshot.active) == "string",
		"the active layout registry snapshot is unavailable")
	assert(snapshot.active_error == nil, "the active registry input-source ownership is ambiguous")
	if snapshot.active == "" then return "ansi" end
	local entry = type(snapshot.installed) == "table" and snapshot.installed[snapshot.active] or nil
	if entry == nil then entry = require("layouts.registry").find_entry(snapshot.index, snapshot.active) end
	assert(type(entry) == "table" and entry.id == snapshot.active,
		"the active registry layout metadata is unavailable")
	local form = entry.keycode_convention
	assert(form == "ansi" or form == "iso", "the active registry layout keycode convention is invalid")
	return form
end

--- Translates Carbon codes to HID names for the selected virtual keyboard.
--- The fixed table describes ANSI; ISO swaps only the two Carbon positions.
--- @param keycode integer Carbon virtual code.
--- @param form string Virtual keyboard form.
--- @return string|nil name Karabiner HID key name.
local function virtual_name(keycode, form)
	return M.product_key_name(KEYCODE_TO_QWERTY_NAME[keycode], form)
end

--- Names a Karabiner output key for the selected virtual keyboard: the ISO
--- product swaps the two ISO-pair usages, so the key that must reach a given
--- keycode is named as the other one.
--- @param name string|nil Karabiner key_code name as the ANSI product receives it.
--- @param product string Virtual keyboard product, "ansi" or "iso".
--- @return string|nil name The name to send through that product.
function M.product_key_name(name, product)
	assert(product == "ansi" or product == "iso", "virtual keyboard form must be ansi or iso")
	if product == "iso" then
		if name == "non_us_backslash" then return "grave_accent_and_tilde" end
		if name == "grave_accent_and_tilde" then return "non_us_backslash" end
	end
	return name
end

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
---
--- Uses direct indexing (map[char]) rather than pairs(map). Some Hammerspoon
--- builds back hs.keycodes.map with a metatable __index that responds to
--- direct lookups but does NOT enumerate via pairs(), which caused earlier
--- revisions to silently fall through to the char fallback.
--- @param char string Single character to resolve (e.g. "c").
--- @param form string|nil Virtual keyboard product the name is for (default: the deployed one).
--- @return string QWERTY key_code name (e.g. "o").
function M.key_code_for_char(char, form)
	local map = get_map()
	if not map then
		Logger.warn(LOG, "hs.keycodes.map unavailable — falling back to '%s'.", tostring(char))
		return char
	end

	-- hs.keycodes.map[char] returns the keycode of the physical key that
	-- produces `char` on the current layout.
	local target_keycode = map[char]

	-- Secondary fallback — iterate numeric keys for older HS builds without
	-- the bidirectional string-key form.
	if type(target_keycode) ~= "number" then
		for k, v in pairs(map) do
			if type(k) == "number" and tostring(v) == char then
				target_keycode = k
				break
			end
		end
	end

	if type(target_keycode) ~= "number" then
		Logger.warn(LOG, "No keycode found for char '%s' — falling back to itself.", tostring(char))
		return char
	end

	-- Resolve keycode → QWERTY name via the fixed table
	-- (NOT via hs.keycodes.map, which would loop back to the layout character)
	local qwerty_name = virtual_name(target_keycode, form or M.default_virtual_keyboard_product())
	if not qwerty_name then
		Logger.warn(LOG, "Keycode %d has no QWERTY name — falling back to char '%s'.",
			target_keycode, tostring(char))
		return char
	end

	return qwerty_name
end


--- Returns the character produced on the current layout by the given QWERTY key name.
--- Example: on Ergopti, physical "O" produces "c", so char_for_key_code("o")
--- returns "c".
--- Falls back to qwerty_name itself on error.
--- @param qwerty_name string QWERTY key name (e.g. "o").
--- @param form string|nil Virtual keyboard product the name is for (default: the deployed one).
--- @return string Character on current layout (e.g. "c").
function M.char_for_key_code(qwerty_name, form)
	local map = get_map()
	if not map then return qwerty_name end

	-- Find the keycode number whose QWERTY name matches the input
	local target_keycode = nil
	form = form or M.default_virtual_keyboard_product()
	for kc in pairs(KEYCODE_TO_QWERTY_NAME) do
		if virtual_name(kc, form) == qwerty_name then
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
