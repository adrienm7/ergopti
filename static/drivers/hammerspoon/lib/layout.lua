--- lib/layout.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Resolver
--- DESCRIPTION:
--- Translates between logical characters and Karabiner key_code names using
--- the OS keyboard layout currently active in macOS.
---
--- FEATURES & RATIONALE:
--- 1. Layout-aware: uses hs.keycodes.map (a live bidirectional table) so the
---    result is always correct for the user's current input source.
--- 2. Shared: avoids duplicating the same lookup logic in every module that
---    needs to map a logical char to a physical key position.
--- 3. Graceful fallback: returns the char itself when hs.keycodes.map is
---    unavailable, which preserves QWERTY behaviour without crashing.
---
--- USAGE:
---   local Layout = require("lib.layout")
---   local key_code = Layout.key_code_for_char("c")   -- → "o" on the user's layout
---   local char     = Layout.char_for_key_code("o")   -- → "c" on the user's layout
--- ==============================================================================

local M = {}
local hs = hs




-- ==============================
-- ==============================
-- ======= 1/ Core Helpers =======
-- ==============================
-- ==============================

--- Returns the current hs.keycodes.map snapshot, or nil on failure.
--- hs.keycodes.map is a bidirectional table:
---   map[keycode_number] → character produced on the CURRENT layout
---   map[qwerty_name]    → keycode number (layout-independent)
--- @return table|nil
local function get_map()
	local ok, map = pcall(function() return hs.keycodes.map end)
	if ok and type(map) == "table" then return map end
	return nil
end


--- Returns the Karabiner key_code name (QWERTY physical key name) that produces
--- the given logical character on the current OS keyboard layout.
--- Example: on a layout where physical "O" produces "c", key_code_for_char("c")
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

	-- Step 2: find the QWERTY name (string key) that maps to that keycode number
	for k, v in pairs(map) do
		if type(k) == "string" and v == target_keycode then
			return k
		end
	end

	return char
end


--- Returns the character produced on the current layout by the given QWERTY key name.
--- Example: on a layout where physical "O" produces "c", char_for_key_code("o")
--- returns "c".
--- Falls back to qwerty_name itself on error.
--- @param qwerty_name string QWERTY key name (e.g. "o").
--- @return string Character on current layout (e.g. "c").
function M.char_for_key_code(qwerty_name)
	local map = get_map()
	if not map then return qwerty_name end

	local keycode = map[qwerty_name]
	if type(keycode) == "number" then
		local char = map[keycode]
		if char then return tostring(char) end
	end

	return qwerty_name
end

return M
