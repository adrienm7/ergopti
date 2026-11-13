--- _shared/layouts/engine/composer/xkb_converter.lua

--- ==============================================================================
--- MODULE: Keylayout to XKB Converter (Shared)
--- DESCRIPTION:
--- Turns the canonical parsed form of a macOS .keylayout (layouts/engine/composer/keylayout.lua)
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

local TableUtil = require("core.text.engine.table_util")

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

-- The number-row options (layout.direct_access_digits, layout.number_row_reorder_edges):
-- the XKB names of the ten digit keys (1 to 0) and of the three edge keys, and which
-- level takes which when a key trades its unshifted and Shift cells (levels 1 to 4 of
-- XKB_LEVELS: base, Caps, Shift, Shift+Caps). Levels 5 to 7 (Ctrl/Alt/Win, AltGr) never move.
local ROW_DIGIT_KEYS = { "AE01", "AE02", "AE03", "AE04", "AE05", "AE06", "AE07", "AE08", "AE09", "AE10" }
local ROW_EDGE_KEYS = { "TLDE", "AE11", "AE12" }
local ROW_LEVEL_PARTNER = { 3, 4, 1, 1 }

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

local function new_converter(layout, keycodes, hints, keysyms, private_states)
	local self = setmetatable({}, Converter)
	self.layout = layout
	-- Dead states whose trigger is borrowed instead of standard, see M.convert.
	self.private_states = private_states
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
	self.swapped = {}
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

--- Keysyms ending a Compose sequence for `action_id` in a dead-key state.
--- A key pressed inside a dead-key state sends what it sends from the neutral state: a
--- dead key sends its own dead keysym, and an action whose one-character id is not
--- what it types sends its output. Naming only base_keysym left those untypable and
--- made a plain action and a dead-key action with the same base keysym collide. The
--- base keysym stays first when a key sends it; a dead key also using the action adds
--- its trigger; an action no key uses keeps its base keysym. A base_level_only key
--- (Ergopti+'s magic key) also adds the keysym its base level sends: inside a dead
--- state macOS types the action's output for it. Twin of state_keysyms in
--- keylayout_to_xkb.py.
function Converter:state_keysyms(action_id)
	local typed = self:keysyms_typing_action(action_id)
	local base = self:base_keysym(action_id)
	if #typed == 0 then return { base } end
	local has_base = false
	for _, keysym in ipairs(typed) do if keysym == base then has_base = true end end
	if not has_base then
		local copy = {}
		for i, keysym in ipairs(typed) do copy[i] = keysym end
		return copy
	end
	local result = { base }
	for _, keysym in ipairs(typed) do
		if keysym ~= base and (self.dead_trigger_values[keysym] or self:is_base_level_only_keysym(keysym)) then
			result[#result + 1] = keysym
		end
	end
	return result
end

--- True when `keysym` is what a base_level_only text (the magic key) types.
function Converter:is_base_level_only_keysym(keysym)
	for text in pairs(self.base_level_only) do
		if ulen(text) == 1 and self:text_keysym(text) == keysym then return true end
	end
	return false
end

--- Keysym a dead key entering `state` produces.
function Converter:dead_trigger(state)
	if self.dead_triggers[state] ~= nil then return self.dead_triggers[state] end
	local terminator = self.layout.terminators[state] or ""
	local keysym = nil
	if self.private_states[state] then
		keysym = nil
	elseif self.borrowed.has(terminator) then
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
			for level in ipairs(self.level_indices) do
				-- A key that traded levels holds at grid level L what its keyMap selects for the partner.
				local source = self.swapped[key[1]] and ROW_LEVEL_PARTNER[level] or level
				local entry = key_entry(self.layout, self.layout.canonical.map_set, self.level_indices[source], key[2], 0)
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

	local explicit = self:explicit_state_keysyms()
	local chain_heads = {}
	for _, seqs in pairs(sequences) do
		for _, seq in ipairs(seqs) do chain_heads[table.concat(seq, " ")] = true end
	end
	local first = true
	local emitted = {}
	local conflicts = {}
	for _, state in ipairs(TableUtil.sorted_keys(outputs)) do
		if sequences[state] ~= nil then
			sort_pairs(outputs[state])
			local terminator = self.layout.terminators[state] or ""
			for _, prefix in ipairs(sequences[state]) do
				if not first then lines[#lines + 1] = "" end
				first = false
				local head_parts = {}
				for i, keysym in ipairs(prefix) do head_parts[i] = "<" .. keysym .. ">" end
				local head = table.concat(head_parts, " ")
				lines[#lines + 1] = head .. "\t: " .. compose_string(self.layout.terminators[state] or "")
				for _, item in ipairs(outputs[state]) do
					for _, keysym in ipairs(self:state_keysyms(item[1])) do
						local sequence = head .. " <" .. keysym .. ">"
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
				if is_printable(terminator) then
					local explicit_here = explicit[state] or {}
					local prefix_key = table.concat(prefix, " ")
					for _, pair in ipairs(self:typed_texts()) do
						local keysym, text = pair[1], pair[2]
						local sequence = head .. " <" .. keysym .. ">"
						if emitted[sequence] == nil and not explicit_here[keysym]
							and not chain_heads[prefix_key .. " " .. keysym] then
							emitted[sequence] = terminator .. text
							lines[#lines + 1] = sequence .. "\t: " .. compose_string(terminator .. text)
						end
					end
				end
			end
		end
	end
	self.conflicts = conflicts
	self.emitted = emitted
	return 'include "%L"\n\n' .. table.concat(lines, "\n") .. "\n"
end

--- Dead states starting a written sequence the locale Compose table extends.
--- @param extended table Set of space-joined keysym sequences.
--- @return table states Array of state names, sorted.
function Converter:shadowed_states(extended)
	local by_trigger = {}
	for state, keysym in pairs(self.dead_triggers) do by_trigger[keysym] = state end
	local found = {}
	for sequence in pairs(self.emitted) do
		local keysyms = {}
		for keysym in sequence:gmatch("<([^>]+)>") do keysyms[#keysyms + 1] = keysym end
		local state = by_trigger[keysyms[1]]
		if extended[table.concat(keysyms, " ")] and state ~= nil and not self.private_states[state] then
			found[#found + 1] = state
		end
	end
	table.sort(found)
	return found
end

--- { keysym, text } of every key/level typing text, in keyboard order. Inside a dead
--- state macOS types the dead key's terminator then what a key with no composition
--- there types; compose() writes that fallback explicitly, since native Compose would
--- cancel the sequence instead. Twin of _typed_texts in keylayout_to_xkb.py.
function Converter:typed_texts()
	local found, seen = {}, {}
	for _, key in ipairs(self.keycodes) do
		for _, cell in ipairs(self.grid[key[1]]) do
			if cell.kind == "text" then
				local keysym = self:text_keysym(cell.text)
				if not seen[keysym] then
					seen[keysym] = true
					found[#found + 1] = { keysym, cell.text }
				end
			end
		end
	end
	return found
end

--- State -> set of keysyms whose action the .keylayout defines in that state: an
--- explicit <when>, even one typing nothing or chaining, never gets the terminator
--- fallback. Twin of _explicit_state_keysyms in keylayout_to_xkb.py.
function Converter:explicit_state_keysyms()
	local explicit = {}
	for _, action_id in ipairs(self.layout.action_ids) do
		for _, when in ipairs(self.layout.actions[action_id].list) do
			if when.state ~= "none" then
				explicit[when.state] = explicit[when.state] or {}
				for _, keysym in ipairs(self:state_keysyms(action_id)) do explicit[when.state][keysym] = true end
			end
		end
	end
	return explicit
end

--- The policy descriptor of a grid cell, as layouts/engine/layout/number_row_policy.lua reads it.
function Converter:row_descriptor(cell)
	if cell.kind == "text" then return { Kind = "text", Text = cell.text } end
	if cell.kind == "dead" then
		local terminator = self.layout.terminators[cell.state]
		return { Kind = "dead", Action = cell.action ~= "" and cell.action or cell.state, State = cell.state,
			Text = (terminator ~= nil and terminator ~= "") and terminator or cell.state }
	end
	return nil
end

--- Applies the number-row options: the unshifted and Shift cells of the digit keys
--- (and of the edge keys when asked and possible) trade places, with the Caps pair,
--- by the rule Windows applies (layouts/engine/layout/number_row_policy.lua, one rule for the
--- drivers). A choice the layout cannot take changes nothing and says why.
--- @param rows table { order = "native"|"digits"|"symbols", edges = boolean }
--- @return table { order, reason, edges = { stored, applies, reason } }
function Converter:apply_rows(rows)
	local Policy = require("layouts.engine.layout.number_row_policy")
	local stored = Policy.mode(rows.order) or "native"
	local edges_stored = rows.edges == true
	local function levels_of(names)
		local list = {}
		for index, name in ipairs(names) do
			local cells = self.grid[name]
			if cells == nil then fail("the key table has no <" .. name .. "> for the number-row options") end
			list[index] = { plain = self:row_descriptor(cells[1]), shift = self:row_descriptor(cells[3]) }
		end
		return list
	end
	local effective = Policy.effective(stored, Policy.availability(levels_of(ROW_DIGIT_KEYS)))
	local edges_reason = edges_stored and Policy.edges_availability(levels_of(ROW_EDGE_KEYS), effective.mode) or ""
	local edges_apply = edges_stored and edges_reason == ""
	local function swap(name)
		local cells = self.grid[name]
		-- Shift takes the unshifted cell and the other way round. Caps takes what the key
		-- typed with Shift and Caps (the digit of a symbols-first row stays under Caps), and
		-- Shift+Caps follows Shift, as the composer's Shift keyMap does (anyShift caps?).
		cells[1], cells[3] = cells[3], cells[1]
		cells[2] = cells[4]
		cells[4] = cells[3]
		self.swapped[name] = true
	end
	if effective.mode ~= "native" then
		for _, name in ipairs(ROW_DIGIT_KEYS) do swap(name) end
		if edges_apply then for _, name in ipairs(ROW_EDGE_KEYS) do swap(name) end end
	end
	return { order = effective.mode, reason = effective.reason,
		edges = { stored = edges_stored, applies = edges_apply, reason = edges_stored and edges_reason or "" } }
end

-- macOS codes of the numeric keypad, which XKB keeps (KEYPAD_CODES in the Python twin).
local KEYPAD_FIRST, KEYPAD_LAST = 65, 92

--- Codes of keys the layout defines (a typing output or an action) that the
--- keycode table names no XKB key for, keypad excepted, ascending. Twin of
--- unplaced_codes in keylayout_to_xkb.py.
--- @param canonical table
--- @param keycodes table Array of { xkb_name, mac_code }.
--- @return table codes
local function unplaced_codes(canonical, keycodes)
	local placed, found, codes = {}, {}, {}
	for _, key in ipairs(keycodes) do placed[key[2]] = true end
	for _, set in ipairs(canonical.key_map_sets or {}) do
		for _, map in ipairs(set.key_maps or {}) do
			for _, key in ipairs(map.keys or {}) do
				local code = key.code
				if not placed[code] and not (code >= KEYPAD_FIRST and code <= KEYPAD_LAST) and not found[code]
					and (key.action ~= nil or (type(key.output) == "string" and is_printable(key.output))) then
					found[code] = true
					codes[#codes + 1] = code
				end
			end
		end
	end
	table.sort(codes)
	return codes
end

--- One conversion pass with the given private dead states (see M.convert).
local function convert_once(canonical, options, private_states)
	local converter
	local ok, result = pcall(function()
		local layout = index_layout(canonical)
		converter = new_converter(layout, options.keycodes, options.hints or {}, options.keysyms, private_states)
		local rows_report = options.rows ~= nil and converter:apply_rows(options.rows) or nil
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
			unplaced = unplaced_codes(canonical, options.keycodes),
			rows = rows_report,
		}
	end)
	if ok then return result, nil, converter end
	if type(result) == "table" and result.keylayout_error then return nil, result.keylayout_error end
	error(result, 0)
end

--- Converts a canonical keylayout to XKB symbols and XCompose text.
--- @param canonical table The schema-1 form (layouts/engine/composer/keylayout.lua).
--- @param options table {
---   keycodes = array of { xkb_name, mac_code } (M.keycodes),
---   keysyms = table character -> keysym name (key_sym.json "keysyms"),
---   template = string (xkb_symbols.txt),
---   layout_id = string (letters, digits, "_"), display_name = string,
---   locale_extended_prefixes = array of space-joined keysym sequences the locale
---     Compose table extends (key_sym.json "locale_extended_prefixes"),
---   hints = { keysym_overrides = { {text, keysym}... }, base_level_only = { text... } } | nil }
--- @return table|nil result { symbols_text, compose_text, conflicts, unplaced }
--- @return string|nil err
function M.convert(canonical, options)
	if type(canonical) ~= "table" or canonical.schema ~= 1 then return nil, "canonical keylayout must be schema 1" end
	if not tostring(options.layout_id):match("^[A-Za-z0-9_]+$") then
		return nil, "layout id '" .. tostring(options.layout_id) .. "' must be letters, digits and _"
	end
	if type(options.locale_extended_prefixes) ~= "table" then
		return nil, "the locale-extended Compose prefixes (key_sym.json) are required"
	end
	local extended = set_of(options.locale_extended_prefixes)
	-- The table starts with include "%L": a locale sequence longer than one of ours
	-- makes Compose skip ours (Bépo's monnaie then cedilla waits for the locale's cedi
	-- sign instead of typing ₢). The dead key starting such a sequence gets a borrowed
	-- trigger, which the locale does not extend, and the conversion runs again until no
	-- written sequence is shadowed.
	local private_states = {}
	while true do
		local result, err, converter = convert_once(canonical, options, private_states)
		if result == nil then return nil, err end
		local shadowed = converter:shadowed_states(extended)
		if #shadowed == 0 then return result end
		for _, state in ipairs(shadowed) do private_states[state] = true end
	end
end

--- Reports how the shipped XKB type projects every source modifier combination.
--- Raw key entries are compared, including action identity, so state-dependent
--- differences are reported even when the neutral text happens to be equal.
--- @param canonical table Schema-1 layout.
--- @param keycodes table Array of { xkb_name, mac_code }.
--- @param types string Shipped xkb_types.txt, the owner of native level selection.
--- @return table report { source_levels, modifier_differences }
function M.projection_report(canonical, keycodes, types)
	local layout, native = index_layout(canonical), {}
	local function signature(tokens)
		table.sort(tokens)
		return table.concat(tokens, "+")
	end
	for keys, level in types:gmatch("map%[([^%]]+)%]%s*=%s*Level(%d+)") do
		local tokens = {}
		for token in keys:gmatch("%a[%w_]*") do if token ~= "None" then tokens[#tokens + 1] = token end end
		level = tonumber(level)
		assert(XKB_LEVELS[level], "unknown XKB projection level")
		native[signature(tokens)] = level
	end
	assert(native[""] == 1, "XKB type has no base mapping")
	local modifiers = { { "shift", "Shift" }, { "caps", "Lock" }, { "option", "LevelThree" }, { "control", "Control" }, { "command", "Mod4" } }
	local differences = {}
	for mask = 0, 31 do
		local source, target = {}, {}
		for bit, pair in ipairs(modifiers) do
			if math.floor(mask / 2 ^ (bit - 1)) % 2 == 1 then source[#source + 1] = pair[1]; target[#target + 1] = pair[2] end
		end
		-- XKB's default level is one for combinations absent from the type map.
		local level = native[signature(target)] or 1
		local original = key_map_index(layout, set_of(source))
		local projected = key_map_index(layout, set_of(XKB_LEVELS[level]))
		local changed = {}
		for _, key in ipairs(keycodes) do
			local before = key_entry(layout, canonical.map_set, original, key[2], 0)
			local after = key_entry(layout, canonical.map_set, projected, key[2], 0)
			if (before == nil) ~= (after == nil) or before and after and (before[1] ~= after[1] or before[2] ~= after[2]) then changed[#changed + 1] = key[2] end
		end
		if #changed > 0 then differences[#differences + 1] = { modifiers = source, level = level, key_codes = changed } end
	end
	local empty, bound = {}, {}
	for level, modifiers_at_level in ipairs(XKB_LEVELS) do
		local index = key_map_index(layout, set_of(modifiers_at_level))
		local codes = {}
		for _, key in ipairs(keycodes) do
			local entry = key_entry(layout, canonical.map_set, index, key[2], 0)
			if entry and entry[1] == "action" then bound[entry[2]] = true end
			if resolve(layout, index, key[2]).kind == "none" then codes[#codes + 1] = key[2] end
		end
		if #codes > 0 then empty[#empty + 1] = { level = level, key_codes = codes } end
	end
	local unbound = {}
	for _, action in ipairs(canonical.actions) do
		for _, when in ipairs(action.whens) do
			if when.state ~= "none" and not bound[action.id] then unbound[#unbound + 1] = action.id; break end
		end
	end
	return { source_levels = TableUtil.deep_copy(XKB_LEVELS), modifier_differences = differences, empty_cells = empty, unbound_actions = unbound }
end

return M
