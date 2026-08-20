--- _shared/lua/keylogger/finger_map.lua

--- ==============================================================================
--- MODULE: Which Finger Types Which Character
--- DESCRIPTION:
--- A character-to-finger and character-to-hand lookup, built from the shared
--- keycode catalogue at `_shared/data/keycodes/azerty.json` — the same file the
--- typing heatmap's key data is generated from.
---
--- WHY BY CHARACTER AND NOT BY KEYCODE:
--- The catalogue is keyed by macOS virtual keycode, which is the only thing
--- macOS has to hand. Linux reads evdev scancodes, and the two numbering schemes
--- share nothing — so a keycode lookup is not portable, and hand-writing an
--- evdev table would be a third answer to a question the catalogue already
--- answers. Every row also carries the qwerty and azerty CHARACTER the key
--- produces, and a character is what every driver has after resolution.
---
--- WHAT THIS IS FOR:
--- The same-finger and same-hand streak analysis. Those two numbers are the
--- whole argument for an alternative layout — "how often does one finger have to
--- move twice in a row" — so a driver that cannot compute them cannot show the
--- panel the layout exists to justify.
---
--- WHAT IT IS NOT:
--- An input method. It says which finger a touch typist WOULD use for a
--- character on a standard keyboard, which is what the metric means; it says
--- nothing about which finger anybody actually used.
--- ==============================================================================

local M = {}

-- The catalogue's own name for "no idea". Returned rather than nil so a caller
-- can tell "not a key this catalogue knows" from "the lookup failed to load",
-- which are different problems with the same symptom.
M.UNKNOWN = "unknown"

-- Decoded lookups, per layout. Built on first use and kept: the catalogue is
-- seventy-odd rows and the walk asks per keystroke.
local _by_layout = {}




-- =========================================
-- =========================================
-- ======= 1/ Building the lookup ==========
-- =========================================
-- =========================================

--- Builds the character → { finger, hand } map for one layout.
---
--- @param catalogue table The decoded azerty.json.
--- @param layout string "qwerty" or "azerty" — which character column to key on.
--- @return table
local function build(catalogue, layout)
	local out = {}
	for _, entry in ipairs(catalogue.keys or {}) do
		local char = entry[layout]
		if type(char) == "string" and char ~= "" and type(entry.finger) == "string" then
			-- Lower and upper both map to the same finger: shift changes the glyph,
			-- not the hand that reaches for it. Without this every capital letter
			-- would break a same-finger run that the user's hand did not break.
			out[char] = { finger = entry.finger, hand = entry.hand or "unknown" }
			local upper = char:upper()
			if upper ~= char then
				out[upper] = { finger = entry.finger, hand = entry.hand or "unknown" }
			end
		end
	end
	return out
end

--- Loads and caches the lookup for a layout.
---
--- @param layout string "qwerty" or "azerty".
--- @param read_file function Given a path, returns its contents or nil.
--- @param decode_json function Given a string, returns a table or raises.
--- @param catalogue_path string Absolute path to azerty.json.
--- @return table|nil The lookup, or nil when the catalogue is unreadable.
function M.load(layout, read_file, decode_json, catalogue_path)
	layout = (layout == "azerty") and "azerty" or "qwerty"
	if _by_layout[layout] ~= nil then
		return _by_layout[layout] or nil
	end
	if type(read_file) ~= "function" or type(decode_json) ~= "function" then
		return nil
	end

	local content = read_file(catalogue_path)
	if type(content) ~= "string" or content == "" then
		-- `false` rather than nil, so a failed read is remembered and the file is
		-- not re-opened once per keystroke for the rest of the session.
		_by_layout[layout] = false
		return nil
	end
	-- A leading UTF-8 BOM is not JSON, and several decoders reject it outright.
	if content:sub(1, 3) == "\239\187\191" then content = content:sub(4) end

	local ok, catalogue = pcall(decode_json, content)
	if not ok or type(catalogue) ~= "table" or type(catalogue.keys) ~= "table" then
		_by_layout[layout] = false
		return nil
	end

	_by_layout[layout] = build(catalogue, layout)
	return _by_layout[layout]
end




-- =========================================
-- =========================================
-- ======= 2/ Asking ========================
-- =========================================
-- =========================================

--- The finger that types a character.
--- @param lookup table|nil From M.load.
--- @param char string
--- @return string The finger name, or M.UNKNOWN.
function M.finger_of(lookup, char)
	if type(lookup) ~= "table" or type(char) ~= "string" then return M.UNKNOWN end
	local entry = lookup[char]
	return (entry and entry.finger) or M.UNKNOWN
end

--- The hand that types a character.
--- @param lookup table|nil From M.load.
--- @param char string
--- @return string "left", "right", or M.UNKNOWN.
function M.hand_of(lookup, char)
	if type(lookup) ~= "table" or type(char) ~= "string" then return M.UNKNOWN end
	local entry = lookup[char]
	return (entry and entry.hand) or M.UNKNOWN
end

--- Test seam: forgets what was loaded.
function M._reset()
	_by_layout = {}
end

return M
