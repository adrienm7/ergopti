--- infra/xkb_keymap.lua

--- ==============================================================================
--- MODULE: XKB Keymap Parser (Linux)
--- DESCRIPTION:
--- Turns the text of an XKB keymap — what `xkbcli dump-keymap-x11` and
--- `dump-keymap-wayland` print — into the mapping injection needs: which
--- keycode, at which level, produces which keysym.
---
--- WHY THIS EXISTS:
--- uinput sends KEYCODES. The compositor then applies the user's XKB layout on
--- top, identically under X11 and Wayland, and that layer is the only one there
--- is. So typing a CHARACTER means solving the inverse problem — character to
--- (keycode, level) under the layout that is actually loaded — and there is
--- exactly one authority for what that layout is: the server's own keymap.
---
--- Assuming US, which is what ydotool does, produces gibberish on AZERTY, BÉPO,
--- Dvorak and German the moment a replacement contains anything but a-z. This
--- driver's replacements are overwhelmingly accented French, so that is not an
--- edge case here, it is the common path.
---
--- WHAT IT DELIBERATELY DOES NOT DO:
--- It does not resolve keysyms to characters. A keysym name is an X11 protocol
--- constant, a character is Unicode, and the mapping between them belongs to
--- libxkbcommon — see infra/keysym.lua. Keeping the two apart is what lets this
--- half be a pure function over text, testable from a fixture with no display
--- server anywhere.
---
--- FEATURES & RATIONALE:
--- 1. Both `key <X> { [ a, A ] }` and the `symbols[Group1]= [ … ]` long form are
---    parsed. Real dumps contain both, in the same file, and a parser that knows
---    only the short one silently drops every key that carries an explicit type
---    — which on a French layout includes most of the interesting ones.
--- 2. Group 1 only, stated rather than assumed. A multi-group keymap is a user
---    who switches layouts with a hotkey; injecting into group 2 while group 1
---    is active types the wrong characters, so the extra groups are dropped
---    here and the active-group question is left to the caller.
--- 3. The X11-to-evdev offset is applied here, once. XKB keycodes are evdev
---    keycodes plus 8, and that constant re-derived at a call site is a
---    keyboard that types eight keys to the left.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.xkb_keymap"




-- ==============================================
-- ==============================================
-- ======= 1/ Constants =========================
-- ==============================================
-- ==============================================

--- XKB keycodes are evdev keycodes offset by 8, because the X11 protocol
--- reserves codes 0-7. The kernel reports 30 for KEY_A and the keymap calls the
--- same key 38.
M.EVDEV_OFFSET = 8

--- The keysym name a keymap uses for "this level produces nothing".
local NO_SYMBOL = "NoSymbol"

--- Levels, and the modifiers that select them on the standard four-level types.
--- Level 5 and above exist (the "level5" types some layouts use) and are
--- deliberately absent: this driver would have to synthesise a modifier it
--- cannot name portably, and returning nothing is better than pressing something
--- arbitrary.
M.LEVEL_MODIFIERS = {
	[1] = {},
	[2] = { "shift" },
	[3] = { "altgr" },
	[4] = { "shift", "altgr" },
}

--- Highest level this module will report.
M.MAX_LEVEL = 4




-- ==============================================
-- ==============================================
-- ======= 2/ Block extraction ==================
-- ==============================================
-- ==============================================

--- Extracts the body of a named top-level block, brace-balanced.
---
--- A pattern match cannot do this: every block contains nested braces, so
--- `xkb_symbols "…" {(.-)}` stops at the first inner closing brace and returns
--- the type definitions instead of the symbols.
--- @param text string Whole keymap dump.
--- @param name string Block name, e.g. "xkb_symbols".
--- @return string|nil The block body without its outer braces.
function M.block(text, name)
	if type(text) ~= "string" then return nil end
	local start = text:find(name, 1, true)
	if not start then return nil end
	local open = text:find("{", start, true)
	if not open then return nil end

	local depth = 0
	for i = open, #text do
		local c = text:sub(i, i)
		if c == "{" then
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 then return text:sub(open + 1, i - 1) end
		end
	end
	return nil
end




-- ==============================================
-- ==============================================
-- ======= 3/ Parsing ===========================
-- ==============================================
-- ==============================================

--- Reads the `<NAME> = N;` table out of the keycodes block.
--- @param text string Whole keymap dump.
--- @return table name → evdev keycode.
function M.parse_keycodes(text)
	local codes = {}
	local body = M.block(text, "xkb_keycodes")
	if not body then
		Logger.warn(LOG, "No xkb_keycodes block — the dump is not a keymap.")
		return codes
	end
	for name, value in body:gmatch("<([%w_+%-]+)>%s*=%s*(%d+)%s*;") do
		local evdev = tonumber(value) - M.EVDEV_OFFSET
		if evdev >= 0 then codes[name] = evdev end
	end
	return codes
end

--- Counts the pairs of a non-array table.
--- @param t table
--- @return integer
local function count_pairs(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

--- Splits one keysym list — the text between `[` and `]` — into level order.
--- @param list string
--- @return table Array of keysym names; NoSymbol becomes false.
local function split_levels(list)
	local levels = {}
	for entry in (list .. ","):gmatch("%s*([^,]-)%s*,") do
		if entry == "" or entry == NO_SYMBOL then
			levels[#levels + 1] = false
		else
			levels[#levels + 1] = entry
		end
	end
	return levels
end

--- Reads the group-1 keysym list for every key in the symbols block.
---
--- Two spellings occur in the same dump. The short form is
--- `key <AD01> { [ a, A, ae, AE ] };` and the long one is
--- `key <TLDE> { type= "FOUR_LEVEL", symbols[Group1]= [ … ] };`. Whichever comes
--- first inside the braces is group 1 in both, so the search is for the first
--- bracketed list that is not an index like `symbols[Group2]`.
--- @param text string Whole keymap dump.
--- @return table key name → array of keysym names (false where NoSymbol).
function M.parse_symbols(text)
	local keys = {}
	local body = M.block(text, "xkb_symbols")
	if not body then
		Logger.warn(LOG, "No xkb_symbols block — the dump is not a keymap.")
		return keys
	end

	for name, definition in body:gmatch("key%s+<([%w_+%-]+)>%s*(%b{})") do
		-- Group 2 and beyond are a user who switches layouts with a hotkey.
		-- Injecting into a group that is not active types the wrong characters,
		-- so only the first group is kept and the active-group question is the
		-- caller's.
		local explicit = definition:match("symbols%s*%[%s*Group1%s*%]%s*=%s*%[([^%]]*)%]")
		local list = explicit or definition:match("%[([^%]]*)%]")
		if list then keys[name] = split_levels(list) end
	end
	return keys
end

--- Parses a whole keymap dump into the entries injection resolves against.
--- @param text string Output of `xkbcli dump-keymap-{x11,wayland}`.
--- @return table Array of { keysym = string, keycode = integer, level = integer }.
function M.parse(text)
	local codes = M.parse_keycodes(text)
	local symbols = M.parse_symbols(text)
	local entries = {}

	for key_name, levels in pairs(symbols) do
		local keycode = codes[key_name]
		if keycode then
			for level, keysym in ipairs(levels) do
				if keysym and level <= M.MAX_LEVEL then
					entries[#entries + 1] = {
						keysym  = keysym,
						keycode = keycode,
						level   = level,
					}
				end
			end
		end
	end

	Logger.debug(LOG, "Keymap parsed: %d key(s), %d symbol entr(ies).",
		count_pairs(codes), #entries)
	return entries
end

return M
