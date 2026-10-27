--- _shared/lua/layouts/xkb_converter.lua

--- ==============================================================================
--- MODULE: Keylayout to XKB Converter (Shared)
--- DESCRIPTION:
--- Turns the canonical parsed form of a macOS .keylayout (layouts/keylayout.lua)
--- into the two files the Linux layout manager installs: an XKB symbols file and
--- an XCompose file. It is the rules of static/ergopti/linux/xkb_generation/
--- keylayout_to_xkb.py, which stays as the repository's regeneration tool and the
--- parity oracle: tools/test/test-keylayout-canonical-parity.cjs compares both
--- converters byte for byte on every registry and archived layout.
---
--- Nothing here is specific to one layout:
--- - the characters of each XKB level are read from the keyMap the layout's own
---   modifierMap selects for that modifier combination;
--- - physical keys come from the shared macOS keycode table, read through the
---   layout's keycode convention;
--- - dead keys come from the layout's actions and terminators, chained dead keys
---   included; their XKB trigger is the standard dead keysym when one exists;
--- - outputs longer than one character go through XCompose.
---
--- FEATURES & RATIONALE:
--- 1. PURE Lua: no io, no logger. The keysym table, the symbols template and the
---    keycode table are injected, so the driver owns where they are read from.
--- 2. Fail fast: an undefined keyMapSet, an undefined action or a template that
---    lacks a key line is an error, never a silent default.
--- 3. Order is part of the output (XCompose lists borrowed keysyms and sequences in
---    the order they are chosen), so every table that Python iterates in insertion
---    order is kept as an ordered list here.
--- ==============================================================================

local TableUtil = require("table_util")

local M = {}

-- Key type every generated key uses; defined by xkb_types.txt.
local TYPE_NAME = "ERGOPTI_SEVEN_LEVEL"

-- The seven levels of that type, each described by the macOS modifiers that
-- produce the same characters. The order is the order of the XKB levels.
local XKB_LEVELS = {
	{},
	{ "caps" },
	{ "shift" },
	{ "shift", "caps" },
	{ "command" },
	{ "option" },
	{ "shift", "option" },
}

local function set_of(list)
	local out = {}
	for _, item in ipairs(list) do out[item] = true end
	return out
end

-- XKB dead keysyms, used as the trigger of a dead key whose state is named after
-- one of them (Kalamine names its states "acute", "greek", ...).
local KNOWN_DEAD_KEYSYMS = set_of({
	"dead_grave", "dead_acute", "dead_circumflex", "dead_tilde", "dead_perispomeni",
	"dead_macron", "dead_breve", "dead_abovedot", "dead_diaeresis", "dead_abovering",
	"dead_doubleacute", "dead_caron", "dead_cedilla", "dead_ogonek", "dead_iota",
	"dead_belowdot", "dead_hook", "dead_horn", "dead_stroke", "dead_abovecomma",
	"dead_abovereversedcomma", "dead_doublegrave", "dead_belowring", "dead_belowmacron",
	"dead_belowcircumflex", "dead_belowtilde", "dead_belowbreve", "dead_belowdiaeresis",
	"dead_invertedbreve", "dead_belowcomma", "dead_currency", "dead_lowline",
	"dead_aboveverticalline", "dead_belowverticalline", "dead_longsolidusoverlay",
	"dead_greek", "dead_hamza",
})

-- XKB dead keysyms by the character a dead key types on its own, for layouts whose
-- state names say nothing (Ergopti's "s1_circumflex" types "^").
local DEAD_KEYSYMS_BY_TERMINATOR = {
	["`"] = "dead_grave", ["\xC2\xB4"] = "dead_acute", ["^"] = "dead_circumflex",
	["~"] = "dead_tilde", ["\xC2\xAF"] = "dead_macron", ["\xCB\x89"] = "dead_macron",
	["\xCB\x98"] = "dead_breve", ["\xCB\x99"] = "dead_abovedot", ["\xC2\xA8"] = "dead_diaeresis",
	["\xCB\x9A"] = "dead_abovering", ["\xCB\x9D"] = "dead_doubleacute", ["\xCB\x87"] = "dead_caron",
	["\xC2\xB8"] = "dead_cedilla", ["\xCB\x9B"] = "dead_ogonek", ["\xC2\xA4"] = "dead_currency",
	["\xC2\xB5"] = "dead_greek",
}

-- Keysyms no layout is expected to type, borrowed to carry an output longer than
-- one character or a dead key without a keysym of its own; XCompose turns each back
-- into its text. Taken in this (sorted) order; a keysym the layout already types is
-- skipped.
local BORROWED_KEYSYMS = {
	"fiveeighths", "fivesixths", "fourfifths", "oneeighth", "onefifth", "onesixth",
	"onethird", "seveneighths", "threeeighths", "threefifths", "twofifths", "twothirds",
}
-- Once those are used up, Unicode private-use keysyms take over.
local PRIVATE_USE_FIRST = 0xF0000

local NO_SYMBOL = "NoSymbol"





-- ====================================
-- ====================================
-- ======= 1/ Text Helpers ============
-- ====================================
-- ====================================

--- Number of code points of a UTF-8 string.
local function ulen(s)
	local count = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then count = count + 1 end
	end
	return count
end

--- First code point of a non-empty UTF-8 string.
local function first_codepoint(s)
	local b = s:byte(1)
	if b < 0x80 then return b end
	local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
	local cp = b % (2 ^ (7 - len))
	for i = 2, len do cp = cp * 64 + (s:byte(i) % 64) end
	return cp
end

local function unicode_keysym(char)
	return string.format("U%04X", first_codepoint(char))
end

--- Whether `text` types something visible (no C0/C1 control character).
local function is_printable(text)
	if text == "" then return false end
	local i, n = 1, #text
	while i <= n do
		local b = text:byte(i)
		if b < 0x20 or b == 0x7F then return false end
		if b == 0xC2 then
			local nb = text:byte(i + 1)
			if nb and nb >= 0x80 and nb <= 0x9F then return false end
		end
		i = i + 1
	end
	return true
end

--- Renders `text` as a Compose string literal (backslash and quote escaped).
local function compose_string(text)
	return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- An insertion-ordered string-keyed map.
local function ordered()
	local keys, values = {}, {}
	local map = { keys = keys, values = values }
	function map.set(key, value)
		if values[key] == nil then keys[#keys + 1] = key end
		values[key] = value
	end
	function map.has(key) return values[key] ~= nil end
	function map.get(key) return values[key] end
	return map
end

local function fail(message) error({ keylayout_error = message }, 0) end

--- Stable sort of tuples { a, b }: by a, then by b (byte order, which is code point
--- order for UTF-8).
local function sort_pairs(list)
	table.sort(list, function(x, y)
		if x[1] ~= y[1] then return x[1] < y[1] end
		return x[2] < y[2]
	end)
end





-- ====================================
-- ====================================
-- ======= 2/ Layout Lookup ===========
-- ====================================
-- ====================================

--- Indexes the canonical form for lookups.
local function index_layout(canonical)
	local sets = {}
	for _, set in ipairs(canonical.key_map_sets) do
		local maps = {}
		for _, key_map in ipairs(set.key_maps) do
			local keys = {}
			for _, key in ipairs(key_map.keys) do
				keys[key.code] = key.output ~= nil and { "output", key.output } or { "action", key.action }
			end
			maps[key_map.index] = { keys = keys, base = key_map.base }
		end
		sets[set.id] = maps
	end
	local actions, action_ids = {}, {}
	for _, action in ipairs(canonical.actions) do
		local whens = {}
		for _, when in ipairs(action.whens) do whens[when.state] = when end
		actions[action.id] = { id = action.id, list = action.whens, whens = whens }
		action_ids[#action_ids + 1] = action.id
	end
	local terminators = {}
	for _, item in ipairs(canonical.terminators) do terminators[item.state] = item.output end
	return { canonical = canonical, sets = sets, actions = actions, action_ids = action_ids, terminators = terminators }
end

--- keyMap index the layout selects when exactly `pressed` (a set) are down.
local function key_map_index(layout, pressed)
	for _, select in ipairs(layout.canonical.selects) do
		for _, modifier in ipairs(select.modifiers) do
			local allowed = set_of(modifier.required)
			local fits = true
			for _, token in ipairs(modifier.required) do
				if not pressed[token] then fits = false end
			end
			for _, token in ipairs(modifier.optional) do allowed[token] = true end
			for token in pairs(pressed) do
				if not allowed[token] then fits = false end
			end
			if fits then return select.index end
		end
	end
	return layout.canonical.default_index
end

--- The <key> of `code` in keyMap `index`, following baseMapSet.
local function key_entry(layout, set_id, index, code, depth)
	if depth > 8 then fail("keyMap base chain is too deep (cycle?)") end
	local maps = layout.sets[set_id]
	if maps == nil then fail("keyMapSet '" .. set_id .. "' is not defined") end
	local map = maps[index]
	if map ~= nil and map.keys[code] ~= nil then return map.keys[code] end
	if map ~= nil and map.base ~= nil then
		return key_entry(layout, map.base.set, map.base.index, code, depth + 1)
	end
	return nil
end

--- What `code` types in keyMap `index` from the neutral state.
local function resolve(layout, index, code)
	local entry = key_entry(layout, layout.canonical.map_set, index, code, 0)
	if entry == nil then return { kind = "none", text = "", state = "", action = "" } end
	local kind, value = entry[1], entry[2]
	if kind == "output" then
		if is_printable(value) then return { kind = "text", text = value, state = "", action = "" } end
		return { kind = "none", text = "", state = "", action = "" }
	end
	local action = layout.actions[value]
	if action == nil then fail("key " .. code .. " uses undefined action '" .. value .. "'") end
	local when = action.whens.none
	local output, next_state = when and when.output, when and when.next
	if next_state ~= nil and next_state ~= "" then
		local terminator = layout.terminators[next_state] or ""
		return { kind = "dead", text = terminator ~= "" and terminator or action.id, state = next_state, action = action.id }
	end
	if output ~= nil and output ~= "" and is_printable(output) then
		return { kind = "text", text = output, state = "", action = action.id }
	end
	return { kind = "none", text = "", state = "", action = "" }
end





-- ====================================
-- ====================================
-- ======= 3/ Conversion ==============
-- ====================================
-- ====================================

--- Reads the shared keycode table for one keycode convention.
--- @param table_data table Decoded mac_keycodes.json.
--- @param convention string "iso" or "ansi".
--- @return table|nil pairs Array of { xkb_name, mac_code }.
--- @return string|nil err
function M.keycodes(table_data, convention)
	local known = false
	for _, name in ipairs(table_data.conventions or {}) do
		if name == convention then known = true end
	end
	if not known then return nil, "unknown keycode convention '" .. tostring(convention) .. "'" end
	local pairs_out = {}
	for _, key in ipairs(table_data.keys) do
		local mac = key.mac
		pairs_out[#pairs_out + 1] = { key.xkb, type(mac) == "table" and mac[convention] or mac }
	end
	return pairs_out
end

local Converter = {}
Converter.__index = Converter

local function new_converter(layout, keycodes, hints, keysyms)
	local self = setmetatable({}, Converter)
	self.layout = layout
	self.keycodes = keycodes
	self.keysyms = keysyms
	self.base_level_only = set_of(hints.base_level_only or {})
	self.level_indices = {}
	for level, modifiers in ipairs(XKB_LEVELS) do
		self.level_indices[level] = key_map_index(layout, set_of(modifiers))
	end
	-- Insertion order matters: XCompose lists these in this order.
	self.borrowed = ordered()
	for _, pair in ipairs(hints.keysym_overrides or {}) do self.borrowed.set(pair[1], pair[2]) end
	self.grid = {}
	for _, key in ipairs(keycodes) do
		local cells = {}
		for level, index in ipairs(self.level_indices) do cells[level] = resolve(layout, index, key[2]) end
		self.grid[key[1]] = cells
	end
	for _, cells in pairs(self.grid) do
		for level = 2, #cells do
			local cell = cells[level]
			if cell.kind == "text" and self.base_level_only[cell.text] and ulen(cell.action) == 1 then
				cell.text = cell.action
			end
		end
	end
	self.taken = {}
	for _, cells in pairs(self.grid) do
		for _, cell in ipairs(cells) do
			if cell.kind == "text" and ulen(cell.text) == 1 and not self.borrowed.has(cell.text) then
				self.taken[self.keysyms[cell.text] or unicode_keysym(cell.text)] = true
			end
		end
	end
	for _, keysym in pairs(self.borrowed.values) do self.taken[keysym] = true end
	self.dead_triggers = {}
	self.dead_trigger_values = {}
	self.dead_trigger_states = {}
	return self
end

function Converter:borrow()
	for _, keysym in ipairs(BORROWED_KEYSYMS) do
		if not self.taken[keysym] then
			self.taken[keysym] = true
			return keysym
		end
	end
	local code = PRIVATE_USE_FIRST
	while self.taken[string.format("U%X", code)] do code = code + 1 end
	local keysym = string.format("U%X", code)
	self.taken[keysym] = true
	return keysym
end

--- Keysym typing `text`; borrows one for multi-character outputs.
function Converter:text_keysym(text)
	if self.borrowed.has(text) then return self.borrowed.get(text) end
	if ulen(text) >= 2 then
		local keysym = self:borrow()
		self.borrowed.set(text, keysym)
		return keysym
	end
	return self.keysyms[text] or unicode_keysym(text)
end

--- Keysym naming the character an action types from the neutral state; used for the
--- key pressed inside a dead-key state.
function Converter:base_keysym(action_id)
	local action = self.layout.actions[action_id]
	local text = action_id
	if action ~= nil and ulen(action_id) ~= 1 then
		local when = action.whens.none
		local output, next_state = when and when.output, when and when.next
		if next_state ~= nil and next_state ~= "" then
			local terminator = self.layout.terminators[next_state] or ""
			text = terminator ~= "" and terminator or action_id
		elseif output ~= nil and output ~= "" then
			text = output
		end
	end
	if self.borrowed.has(text) then return self.borrowed.get(text) end
	if ulen(text) == 1 then return self.keysyms[text] or unicode_keysym(text) end
	return self.keysyms[text] or text
end

--- Keysym a dead key entering `state` produces.
function Converter:dead_trigger(state)
	if self.dead_triggers[state] ~= nil then return self.dead_triggers[state] end
	local terminator = self.layout.terminators[state] or ""
	local keysym = nil
	if self.borrowed.has(terminator) then
		keysym = self.borrowed.get(terminator)
	elseif KNOWN_DEAD_KEYSYMS["dead_" .. state] then
		keysym = "dead_" .. state
	elseif DEAD_KEYSYMS_BY_TERMINATOR[terminator] then
		keysym = DEAD_KEYSYMS_BY_TERMINATOR[terminator]
	elseif ulen(terminator) == 1 and self.keysyms[terminator] then
		local named = self.keysyms[terminator]
		if not self.taken[named] then keysym = named end
	end
	if keysym == nil or self.dead_trigger_values[keysym] then keysym = self:borrow() end
	self.taken[keysym] = true
	self.dead_triggers[state] = keysym
	self.dead_trigger_values[keysym] = true
	self.dead_trigger_states[#self.dead_trigger_states + 1] = state
	return keysym
end

function Converter:cell_keysym(cell)
	if cell.kind == "dead" then return self:dead_trigger(cell.state) end
	if cell.kind == "text" then return self:text_keysym(cell.text) end
	return nil
end

--- Keysyms of every key/level whose <key> uses `action_id`.
function Converter:keysyms_typing_action(action_id)
	if self.action_keysyms == nil then
		local by_action, seen = {}, {}
		for _, key in ipairs(self.keycodes) do
			for level, index in ipairs(self.level_indices) do
				local entry = key_entry(self.layout, self.layout.canonical.map_set, index, key[2], 0)
				if entry ~= nil and entry[1] == "action" then
					local keysym = self:cell_keysym(self.grid[key[1]][level])
					by_action[entry[2]] = by_action[entry[2]] or {}
					seen[entry[2]] = seen[entry[2]] or {}
					if keysym and not seen[entry[2]][keysym] then
						seen[entry[2]][keysym] = true
						table.insert(by_action[entry[2]], keysym)
					end
				end
			end
		end
		self.action_keysyms = by_action
	end
	return self.action_keysyms[action_id] or {}
end

--- Keysym sequences entering each dead-key state, chains included.
function Converter:dead_sequences()
	local sequences, seen = {}, {}
	local function add(state, sequence)
		local key = table.concat(sequence, "\0")
		sequences[state] = sequences[state] or {}
		seen[state] = seen[state] or {}
		if seen[state][key] then return false end
		seen[state][key] = true
		table.insert(sequences[state], sequence)
		return true
	end
	for _, key in ipairs(self.keycodes) do
		for _, cell in ipairs(self.grid[key[1]]) do
			if cell.kind == "dead" then add(cell.state, { self:dead_trigger(cell.state) }) end
		end
	end
	-- A chained dead key is an action that, inside state P, moves to state S.
	-- Iterate to a fixed point so chains of any length are found.
	local changed, rounds = true, 0
	local ids = {}
	for _, id in ipairs(self.layout.action_ids) do ids[#ids + 1] = id end
	table.sort(ids)
	while changed do
		rounds = rounds + 1
		if rounds > 16 then fail("dead-key chains do not terminate") end
		changed = false
		for _, action_id in ipairs(ids) do
			local action = self.layout.actions[action_id]
			for _, when in ipairs(action.list) do
				local state, next_state = when.state, when.next
				if state ~= "none" and next_state ~= nil and next_state ~= "" and sequences[state] ~= nil then
					local prefixes = {}
					for i, prefix in ipairs(sequences[state]) do prefixes[i] = prefix end
					for _, prefix in ipairs(prefixes) do
						for _, keysym in ipairs(self:keysyms_typing_action(action_id)) do
							local candidate = {}
							for i, item in ipairs(prefix) do candidate[i] = item end
							candidate[#candidate + 1] = keysym
							if add(next_state, candidate) then changed = true end
						end
					end
				end
			end
		end
	end
	return sequences
end

--- The XKB symbols file.
function Converter:symbols(template, layout_id, display_name)
	local text = template:gsub('xkb_symbols%s+"[^"]+"', function() return 'xkb_symbols "' .. layout_id .. '"' end)
	text = text:gsub('name%[Group1%]%s*=%s*"[^"]+";', function() return 'name[Group1] = "' .. display_name .. '";' end)
	for _, key in ipairs(self.keycodes) do
		local xkb = key[1]
		local names, comments = {}, {}
		for _, cell in ipairs(self.grid[xkb]) do
			names[#names + 1] = self:cell_keysym(cell) or NO_SYMBOL
			local shown = cell.kind ~= "none" and cell.text or ""
			comments[#comments + 1] = ulen(shown) >= 2 and ('"' .. shown .. '"') or shown
		end
		local line = string.format('key <%s> { type[group1] = "%s", [%s] }; // %s',
			xkb, TYPE_NAME, table.concat(names, ", "), table.concat(comments, " "))
		-- Exactly one `key <XXXX>[^\n]*;` match: from the key to the last ";" of its line.
		local needle = "key <" .. xkb .. ">"
		local matches, from = {}, 1
		while true do
			local s, e = text:find(needle, from, true)
			if not s then break end
			local eol = text:find("\n", e + 1, true) or (#text + 1)
			local last_semicolon = nil
			for position = e + 1, eol - 1 do
				if text:byte(position) == 59 then last_semicolon = position end
			end
			if last_semicolon then
				matches[#matches + 1] = { s, last_semicolon }
				from = last_semicolon + 1
			else
				from = e + 1
			end
		end
		if #matches ~= 1 then fail("the symbols template has no single line for <" .. xkb .. ">") end
		text = text:sub(1, matches[1][1] - 1) .. line .. text:sub(matches[1][2] + 1)
	end
	return text
end

--- The XCompose file.
function Converter:compose()
	local sequences = self:dead_sequences()
	local dead_texts = {}
	for _, state in ipairs(self.dead_trigger_states) do dead_texts[self.layout.terminators[state] or ""] = true end
	local lines = {}
	for _, text in ipairs(self.borrowed.keys) do
		local keysym = self.borrowed.get(text)
		if not (dead_texts[text] and self.dead_trigger_values[keysym]) then
			lines[#lines + 1] = "<" .. keysym .. "> : " .. compose_string(text)
		end
	end
	lines[#lines + 1] = ""

	local outputs = {}
	for _, action_id in ipairs(self.layout.action_ids) do
		for _, when in ipairs(self.layout.actions[action_id].list) do
			if when.state ~= "none" and when.output ~= nil and when.output ~= "" then
				outputs[when.state] = outputs[when.state] or {}
				table.insert(outputs[when.state], { action_id, when.output })
			end
		end
	end

	local first = true
	local emitted = {}
	local conflicts, unreachable = {}, {}
	for _, state in ipairs(TableUtil.sorted_keys(outputs)) do
		if sequences[state] ~= nil then
			sort_pairs(outputs[state])
			for _, item in ipairs(outputs[state]) do
				-- An action no key uses cannot be typed on macOS either.
				local typed = self:keysyms_typing_action(item[1])
				if #typed > 0 then
					local base, found = self:base_keysym(item[1]), false
					for _, keysym in ipairs(typed) do if keysym == base then found = true end end
					if not found then unreachable[#unreachable + 1] = { state, item[1] } end
				end
			end
			for _, prefix in ipairs(sequences[state]) do
				if not first then lines[#lines + 1] = "" end
				first = false
				local head_parts = {}
				for i, keysym in ipairs(prefix) do head_parts[i] = "<" .. keysym .. ">" end
				local head = table.concat(head_parts, " ")
				lines[#lines + 1] = head .. "\t: " .. compose_string(self.layout.terminators[state] or "")
				for _, item in ipairs(outputs[state]) do
					local sequence = head .. " <" .. self:base_keysym(item[1]) .. ">"
					if emitted[sequence] ~= nil then
						if emitted[sequence] ~= item[2] then
							conflicts[#conflicts + 1] = { sequence, emitted[sequence], item[2] }
						end
					else
						emitted[sequence] = item[2]
						lines[#lines + 1] = sequence .. "\t: " .. compose_string(item[2])
					end
				end
			end
		end
	end
	self.conflicts, self.unreachable = conflicts, unreachable
	return 'include "%L"\n\n' .. table.concat(lines, "\n") .. "\n"
end

--- Converts a canonical keylayout to XKB symbols and XCompose text.
--- @param canonical table The schema-1 form (layouts/keylayout.lua).
--- @param options table {
---   keycodes = array of { xkb_name, mac_code } (M.keycodes),
---   keysyms = table character -> keysym name (key_sym.json "keysyms"),
---   template = string (xkb_symbols.txt),
---   layout_id = string (letters, digits, "_"), display_name = string,
---   hints = { keysym_overrides = { {text, keysym}... }, base_level_only = { text... } } | nil }
--- @return table|nil result { symbols_text, compose_text, conflicts, unreachable }
--- @return string|nil err
function M.convert(canonical, options)
	if type(canonical) ~= "table" or canonical.schema ~= 1 then return nil, "canonical keylayout must be schema 1" end
	if not tostring(options.layout_id):match("^[A-Za-z0-9_]+$") then
		return nil, "layout id '" .. tostring(options.layout_id) .. "' must be letters, digits and _"
	end
	local ok, result = pcall(function()
		local layout = index_layout(canonical)
		local converter = new_converter(layout, options.keycodes, options.hints or {}, options.keysyms)
		-- Dead triggers first, in state order, so borrowed keysyms do not depend on the
		-- order keys happen to be listed in.
		local states, seen = {}, {}
		for _, key in ipairs(options.keycodes) do
			for _, cell in ipairs(converter.grid[key[1]]) do
				if cell.kind == "dead" and not seen[cell.state] then
					seen[cell.state] = true
					states[#states + 1] = cell.state
				end
			end
		end
		table.sort(states)
		for _, state in ipairs(states) do converter:dead_trigger(state) end
		local symbols_text = converter:symbols(options.template, options.layout_id, options.display_name)
		local compose_text = converter:compose()
		return {
			symbols_text = symbols_text,
			compose_text = compose_text,
			conflicts = converter.conflicts,
			unreachable = converter.unreachable,
		}
	end)
	if ok then return result end
	if type(result) == "table" and result.keylayout_error then return nil, result.keylayout_error end
	error(result, 0)
end

return M
