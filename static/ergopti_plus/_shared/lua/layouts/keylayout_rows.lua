--- _shared/lua/layouts/keylayout_rows.lua

--- ==============================================================================
--- MODULE: Keylayout Number-Row Options (Shared)
--- DESCRIPTION:
--- Applies the number-row options (layout.direct_access_digits and
--- layout.number_row_reorder_edges) to the TEXT of a macOS .keylayout, so the
--- macOS driver installs a layout that already types them
--- (docs/design/layout-option-emulation.md, sections 2 and 3.1). Also gives a
--- build its own keyboard name and id, and reads back what the number row types,
--- which the driver compares with what the system reports once it is selected.
---
--- FEATURES & RATIONALE:
--- 1. One rule for every converter: the unshifted and Shift cells of the ten digit
---    keys (and of the three edge keys when asked and possible) trade places, Caps
---    takes what the key typed with Shift and Caps, and Shift+Caps follows Shift;
---    availability and refusal reasons come from layout/number_row_policy.lua. The
---    Linux converter applies the same rule to its grid (xkb_converter.lua), and
---    tools/test/test-keylayout-row-options.cjs requires both to give the same
---    XKB files on every case of row_options_vectors.json.
--- 2. Only the keyMaps the plain, Shift, Caps and Shift+Caps presses select in the
---    default keyMapSet change, so Cmd, Ctrl and Option keep the layout's own
---    cells: a Cmd, Ctrl or Option press that selected one of those keyMaps (often
---    through defaultIndex) is routed to a verbatim copy of it first.
--- 3. Cells are moved, never invented: an action keeps its dead-key state machine
---    because the <key> element is moved with its action reference.
--- 4. A versioned build gets a new keyboard id derived from its name with the
---    composer's own rule (composer_model.js keyboardId), because macOS keeps
---    typing the cells it cached for an id it has seen (probe M3).
--- 5. PURE Lua (LuaJIT and Lua 5.4), no io: the caller reads and writes files.
---    Comments are dropped from the written text; the system ignores them.
--- ==============================================================================

local Keylayout = require("layouts.keylayout")
local Policy = require("layout.number_row_policy")
local TableUtil = require("table_util")

local M = {}

-- The keys the options move, by their XKB name in mac_keycodes.json: the ten
-- digit keys (1 to 0), then the three edge keys (left of 1, right of 0 twice).
M.DIGIT_KEYS = { "AE01", "AE02", "AE03", "AE04", "AE05", "AE06", "AE07", "AE08", "AE09", "AE10" }
M.EDGE_KEYS = { "TLDE", "AE11", "AE12" }

-- The presses whose keyMaps the options rewrite.
local ROLES = {
	plain = {},
	caps = { "caps" },
	shift = { "shift" },
	shift_caps = { "shift", "caps" },
}

-- composer_model.js keyboardId: a stable negative id from the name (FNV-1a over
-- code points, 32 bits). The single-source test compares both on the same names.
local KEYBOARD_ID_BASE = 2700000
local KEYBOARD_ID_SPAN = 100000
local FNV_OFFSET = 0x811c9dc5
local FNV_PRIME_HIGH = 0x1000000 -- FNV prime 0x01000193 = 2^24 + 403
local FNV_PRIME_LOW = 403
local TWO_32 = 4294967296





-- ====================================
-- ====================================
-- ======= 1/ Helpers =================
-- ====================================
-- ====================================

local function fail(message) error({ keylayout_rows_error = message }, 0) end

--- Bitwise XOR of two unsigned 32-bit integers, without a bit library (LuaJIT and 5.4).
local function xor32(a, b)
	local result, bit = 0, 1
	for _ = 1, 32 do
		local x, y = a % 2, b % 2
		if x ~= y then result = result + bit end
		a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
	end
	return result
end

--- The code points of a UTF-8 string.
local function codepoints(text)
	local list, i = {}, 1
	while i <= #text do
		local b = text:byte(i)
		local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
		local cp = len == 1 and b or b % (2 ^ (7 - len))
		for k = 2, len do cp = cp * 64 + ((text:byte(i + k - 1) or 0x80) % 64) end
		list[#list + 1] = math.floor(cp)
		i = i + len
	end
	return list
end

--- Whether `text` types something visible (the XKB converter's rule).
local function is_printable(text)
	if text == "" then return false end
	for i = 1, #text do
		local b = text:byte(i)
		if b < 0x20 or b == 0x7F then return false end
		if b == 0xC2 then
			local nb = text:byte(i + 1)
			if nb and nb >= 0x80 and nb <= 0x9F then return false end
		end
	end
	return true
end

--- Escapes an attribute value the way the composer writes one.
local function escape_attribute(value)
	return (value:gsub("[&<>\"%c]", function(c)
		if c == "&" then return "&amp;" end
		if c == "<" then return "&lt;" end
		if c == ">" then return "&gt;" end
		if c == '"' then return "&quot;" end
		return string.format("&#x%04X;", c:byte())
	end))
end

local function set_of(list)
	local set = {}
	for _, item in ipairs(list) do set[item] = true end
	return set
end





-- ====================================
-- ====================================
-- ======= 2/ Layout Lookup ===========
-- ====================================
-- ====================================

--- The keyMap index of the default keyMapSet that exactly `pressed` selects.
local function key_map_index(canonical, pressed)
	for _, select in ipairs(canonical.selects) do
		for _, modifier in ipairs(select.modifiers) do
			local allowed, fits = set_of(modifier.required), true
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
	return canonical.default_index
end

--- Indexes keyMaps and actions of the canonical form.
local function index_layout(canonical)
	local sets = {}
	for _, set in ipairs(canonical.key_map_sets) do
		local maps = {}
		for _, key_map in ipairs(set.key_maps) do
			local keys = {}
			for _, key in ipairs(key_map.keys) do keys[key.code] = key end
			maps[key_map.index] = { keys = keys, base = key_map.base }
		end
		sets[set.id] = maps
	end
	local actions = {}
	for _, action in ipairs(canonical.actions) do
		local whens = {}
		for _, when in ipairs(action.whens) do whens[when.state] = when end
		actions[action.id] = { id = action.id, whens = whens }
	end
	local terminators = {}
	for _, item in ipairs(canonical.terminators) do terminators[item.state] = item.output end
	return { canonical = canonical, sets = sets, actions = actions, terminators = terminators }
end

--- The <key> of `code` in keyMap `index`, following baseMapSet; nil when none.
local function key_entry(layout, set_id, index, code, depth)
	if depth > 8 then fail("keyMap base chain is too deep (cycle?)") end
	local maps = layout.sets[set_id]
	if maps == nil then fail("keyMapSet '" .. tostring(set_id) .. "' is not defined") end
	local map = maps[index]
	if map ~= nil and map.keys[code] ~= nil then return map.keys[code] end
	if map ~= nil and map.base ~= nil then return key_entry(layout, map.base.set, map.base.index, code, depth + 1) end
	return nil
end

--- The policy descriptor (layout/number_row_policy.lua) of what a <key> types
--- from the neutral state, or nil when it types nothing.
local function descriptor(layout, entry)
	if entry == nil then return nil end
	if entry.output ~= nil then
		return is_printable(entry.output) and { Kind = "text", Text = entry.output } or nil
	end
	local action = layout.actions[entry.action]
	if action == nil then fail("key " .. entry.code .. " uses undefined action '" .. tostring(entry.action) .. "'") end
	local when = action.whens.none
	if when ~= nil and when.next ~= nil and when.next ~= "" then
		local terminator = layout.terminators[when.next] or ""
		return { Kind = "dead", Action = action.id, State = when.next,
			Text = terminator ~= "" and terminator or when.next }
	end
	if when ~= nil and when.output ~= nil and is_printable(when.output) then
		return { Kind = "text", Text = when.output }
	end
	return nil
end

--- The macOS key codes of the moved keys for one keycode convention.
--- @param table_data table Decoded _shared/modules/layouts/mac_keycodes.json.
--- @param convention string "iso" or "ansi".
--- @return table|nil codes { digits = { 10 codes }, edges = { 3 codes } }
--- @return string|nil err
function M.key_codes(table_data, convention)
	if type(table_data) ~= "table" or type(table_data.keys) ~= "table" then return nil, "the keycode table is malformed" end
	local known = false
	for _, name in ipairs(table_data.conventions or {}) do known = known or name == convention end
	if not known then return nil, "unknown keycode convention '" .. tostring(convention) .. "'" end
	local by_name = {}
	for _, key in ipairs(table_data.keys) do
		local mac = key.mac
		by_name[key.xkb] = type(mac) == "table" and mac[convention] or mac
	end
	local function collect(names)
		local list = {}
		for index, name in ipairs(names) do
			if type(by_name[name]) ~= "number" then return nil end
			list[index] = by_name[name]
		end
		return list
	end
	local digits, edges = collect(M.DIGIT_KEYS), collect(M.EDGE_KEYS)
	if not digits or not edges then return nil, "the keycode table lacks a number-row key" end
	return { digits = digits, edges = edges }
end





-- ====================================
-- ====================================
-- ======= 3/ Text Editing ============
-- ====================================
-- ====================================

--- The <key> element that types `entry` (nil types nothing) for `code`.
local function key_element(code, entry)
	if entry ~= nil and entry.action ~= nil then
		return '<key code="' .. code .. '" action="' .. escape_attribute(entry.action) .. '"/>'
	end
	local output = entry ~= nil and entry.output or ""
	return '<key code="' .. code .. '" output="' .. escape_attribute(output) .. '"/>'
end

--- Rewrites the keys of the listed keyMaps of one keyMapSet.
--- @param body string Comment-free .keylayout text.
--- @param set_id string keyMapSet id.
--- @param edits table index -> { [code] = entry or false (types nothing) }.
--- @return string body
local function rewrite_keymaps(body, set_id, edits)
	local positions, positions_err = Keylayout.positions(body)
	if not positions then fail(positions_err) end
	local set = positions.key_map_sets[set_id]
	if set == nil then fail("keyMapSet '" .. set_id .. "' is not in the text") end
	local targets = {}
	for index, edit in pairs(edits) do
		local map = set.maps[index]
		if map == nil then fail("keyMap index " .. index .. " of keyMapSet '" .. set_id .. "' is not defined") end
		if map.stop == nil then fail("keyMap index " .. index .. " is not closed") end
		targets[#targets + 1] = { map = map, edit = edit }
	end
	table.sort(targets, function(a, b) return a.map.start < b.map.start end)
	local out, pos = {}, 1
	for _, target in ipairs(targets) do
		local map, edit = target.map, target.edit
		local open_text = body:sub(map.start, map.open_stop - 1)
		local content = ""
		if map.self_closing then
			open_text = open_text:gsub("%s*/>$", ">")
		else
			content = body:sub(map.open_stop, map.close_start - 1)
		end
		-- Every <key> of a moved code goes: the reader keeps the first one only.
		local kept, kpos = {}, 1
		for _, key in ipairs(Keylayout.key_positions(content)) do
			if edit[key.code] ~= nil then
				if not key.self_closing then fail("key " .. key.code .. " holds an inline action") end
				kept[#kept + 1] = content:sub(kpos, key.start - 1)
				kpos = key.stop
			end
		end
		kept[#kept + 1] = content:sub(kpos)
		local added = {}
		for _, code in ipairs(TableUtil.sorted_keys(edit)) do
			added[#added + 1] = "\n      " .. key_element(code, edit[code] or nil)
		end
		out[#out + 1] = body:sub(pos, map.start - 1)
		out[#out + 1] = open_text .. table.concat(added) .. table.concat(kept) .. "</keyMap>"
		pos = map.stop
	end
	out[#out + 1] = body:sub(pos)
	return table.concat(out)
end





-- ====================================
-- ====================================
-- ======= 4/ Public API ==============
-- ====================================
-- ====================================

--- What the ten digit keys and the three edge keys type unshifted and with Shift.
--- @param text string .keylayout text.
--- @param codes table From M.key_codes.
--- @return table|nil cells { digits = { { plain, shift }... }, edges = { ... } } of policy descriptors.
--- @return string|nil err
function M.cells(text, codes)
	local canonical, parse_err = Keylayout.parse(text)
	if not canonical then return nil, parse_err end
	local ok, result = pcall(function()
		local layout = index_layout(canonical)
		local plain = key_map_index(canonical, set_of(ROLES.plain))
		local shift = key_map_index(canonical, set_of(ROLES.shift))
		local function levels(list)
			local out = {}
			for index, code in ipairs(list) do
				out[index] = {
					plain = descriptor(layout, key_entry(layout, canonical.map_set, plain, code, 0)),
					shift = descriptor(layout, key_entry(layout, canonical.map_set, shift, code, 0)),
				}
			end
			return out
		end
		return { digits = levels(codes.digits), edges = levels(codes.edges) }
	end)
	if ok then return result end
	if type(result) == "table" and result.keylayout_rows_error then return nil, result.keylayout_rows_error end
	error(result, 0)
end

--- Whether two <key> entries type the same (false types nothing).
local function same_entry(a, b)
	if a == false or b == false then return a == b end
	return a.output == b.output and a.action == b.action
end

--- Every set of the five modifiers a .keylayout tells apart, each once.
local function modifier_sets()
	local names, sets = { "shift", "caps", "option", "command", "control" }, {}
	for mask = 0, 31 do
		local set, list, bit = {}, {}, mask
		for _, name in ipairs(names) do
			if bit % 2 == 1 then
				set[name] = true
				list[#list + 1] = name
			end
			bit = math.floor(bit / 2)
		end
		sets[#sets + 1] = { set = set, list = list }
	end
	return sets
end

-- The modifierMap token that reads one folded modifier on either side.
local SELECT_TOKENS = { shift = "anyShift", caps = "caps", option = "anyOption", command = "command",
	control = "anyControl" }

--- Gives every other press that selected a rewritten keyMap a verbatim copy of the
--- keyMap as it was, so Cmd, Ctrl and Option keep the layout's cells (the XKB
--- converter reads those levels before the swap too).
--- @param body string Comment-free text, before the rewrite.
--- @param canonical table
--- @param copies table Array of { index, presses = { { list }... } }, by source index.
--- @return function apply(rewritten_body) -> body
local function split_shortcuts(body, canonical, copies)
	if #copies == 0 then return function(text) return text end end
	if #canonical.key_map_sets ~= 1 then
		fail("several_key_map_sets: a press shares a moved keyMap and the layout has several keyMapSets")
	end
	local positions, positions_err = Keylayout.positions(body)
	if not positions then fail(positions_err) end
	local set = positions.key_map_sets[canonical.map_set]
	local modifiers_id = positions.default_modifiers
	if set == nil or modifiers_id == nil then fail('no <layout first="0"> modifiers or keyMapSet') end
	local next_index = 0
	for index in pairs(set.maps) do if index >= next_index then next_index = index + 1 end end
	local maps, selects = {}, {}
	for _, copy in ipairs(copies) do
		local map = set.maps[copy.index]
		if map == nil or map.stop == nil then fail("keyMap index " .. copy.index .. " is not in the text") end
		local original = body:sub(map.start, map.stop - 1)
		local index = next_index
		next_index = next_index + 1
		maps[#maps + 1] = "\n    " .. original:gsub('^([^>]-%sindex%s*=%s*)"[^"]*"', '%1"' .. index .. '"', 1)
		for _, press in ipairs(copy.presses) do
			local tokens = {}
			for _, name in ipairs(press) do tokens[#tokens + 1] = SELECT_TOKENS[name] end
			selects[#selects + 1] = '\n    <keyMapSelect mapIndex="' .. index .. '"><modifier keys="'
				.. table.concat(tokens, " ") .. '"/></keyMapSelect>'
		end
	end
	return function(text)
		local after, after_err = Keylayout.positions(text)
		if not after then fail(after_err) end
		local close = after.key_map_sets[canonical.map_set].close_start
		local modifier_map = after.modifier_maps[modifiers_id]
		if close == nil then fail("the keyMapSet is not closed") end
		if modifier_map == nil or modifier_map.self_closing then fail("modifierMap '" .. modifiers_id .. "' is empty") end
		-- First match wins: the exact presses go first, so nothing else changes. The
		-- later position is edited first so the earlier one stays valid.
		local insertions = {
			{ at = close, text = table.concat(maps) .. "\n  " },
			{ at = modifier_map.open_stop, text = table.concat(selects) },
		}
		table.sort(insertions, function(a, b) return a.at > b.at end)
		for _, insertion in ipairs(insertions) do
			text = text:sub(1, insertion.at - 1) .. insertion.text .. text:sub(insertion.at)
		end
		return text
	end
end

--- Applies the number-row options to a .keylayout.
--- @param text string .keylayout text.
--- @param rows table { order = "native"|"digits"|"symbols", edges = boolean }
--- @param codes table From M.key_codes.
--- @return table|nil result { text, changed, report = { order, reason, edges = { stored, applies, reason } } }
--- @return string|nil err Why the layout cannot take the options (nothing is changed).
function M.apply(text, rows, codes)
	if type(rows) ~= "table" then return nil, "the number-row options are missing" end
	local canonical, parse_err = Keylayout.parse(text)
	if not canonical then return nil, parse_err end
	local ok, result = pcall(function()
		local layout = index_layout(canonical)
		local cells, cells_err = M.cells(text, codes)
		if not cells then fail(cells_err) end
		local stored = Policy.mode(rows.order) or "native"
		local edges_stored = rows.edges == true
		local effective = Policy.effective(stored, Policy.availability(cells.digits))
		local edges_reason = edges_stored and Policy.edges_availability(cells.edges, effective.mode) or ""
		local edges_apply = edges_stored and edges_reason == ""
		local report = { order = effective.mode, reason = effective.reason,
			edges = { stored = edges_stored, applies = edges_apply, reason = edges_stored and edges_reason or "" } }
		if effective.mode == "native" then return { text = text, changed = false, report = report } end

		local index, role_of_index = {}, {}
		for role, modifiers in pairs(ROLES) do
			index[role] = key_map_index(canonical, set_of(modifiers))
			role_of_index[index[role]] = true
		end
		-- Every other press that lands on a rewritten keyMap keeps a copy of it.
		local copies, copy_of = {}, {}
		for _, press in ipairs(modifier_sets()) do
			local role_press = not (press.set.option or press.set.command or press.set.control)
			local selected = key_map_index(canonical, press.set)
			if not role_press and role_of_index[selected] then
				if not copy_of[selected] then
					copy_of[selected] = { index = selected, presses = {} }
					copies[#copies + 1] = copy_of[selected]
				end
				local presses = copy_of[selected].presses
				presses[#presses + 1] = press.list
			end
		end
		table.sort(copies, function(a, b) return a.index < b.index end)
		local body = Keylayout.strip_comments(text)
		local add_copies = split_shortcuts(body, canonical, copies)

		local moved = {}
		for _, code in ipairs(codes.digits) do moved[#moved + 1] = code end
		if edges_apply then for _, code in ipairs(codes.edges) do moved[#moved + 1] = code end end
		local edits = {}
		for _, role_index in pairs(index) do edits[role_index] = {} end
		for _, code in ipairs(moved) do
			local function old(role) return key_entry(layout, canonical.map_set, index[role], code, 0) or false end
			-- Shift takes the unshifted cell and the other way round; Caps takes what the
			-- key typed with Shift and Caps, and Shift+Caps follows the new Shift.
			local new = { plain = old("shift"), shift = old("plain"), caps = old("shift_caps"), shift_caps = old("plain") }
			for role, entry in pairs(new) do
				local edit = edits[index[role]]
				if edit[code] ~= nil and not same_entry(edit[code], entry) then
					fail("shared_keymap: keyMap " .. index[role] .. " serves two presses that now differ on key " .. code)
				end
				edit[code] = entry
			end
		end
		body = add_copies(rewrite_keymaps(body, canonical.map_set, edits))
		return { text = body, changed = true, report = report }
	end)
	if ok then return result end
	if type(result) == "table" and result.keylayout_rows_error then return nil, result.keylayout_rows_error end
	error(result, 0)
end

--- The keyboard id the composer derives from a name (composer_model.js keyboardId).
--- @param name string
--- @return integer id A negative integer.
function M.keyboard_id(name)
	local hash = FNV_OFFSET
	for _, cp in ipairs(codepoints(name)) do
		hash = xor32(hash, cp)
		hash = ((hash % 256) * FNV_PRIME_HIGH + hash * FNV_PRIME_LOW) % TWO_32
	end
	return math.floor(-(KEYBOARD_ID_BASE + (hash % KEYBOARD_ID_SPAN)))
end

--- Gives a .keylayout a new keyboard name and the id derived from it.
--- @param text string .keylayout text.
--- @param name string The new keyboard name.
--- @return string|nil text
--- @return string|nil err
function M.rename(text, name)
	if type(name) ~= "string" or name == "" or not is_printable(name) then return nil, "the keyboard name is empty or not printable" end
	local open = text:find("<keyboard[%s>]")
	local tag = open and Keylayout.match_tag(text, open) or nil
	if not tag or tag.closing then return nil, "no <keyboard> element" end
	if tag.attrs.name == nil or tag.attrs.id == nil then return nil, "the <keyboard> element lacks its name or id" end
	local head = text:sub(open, tag.next - 1)
	local id = M.keyboard_id(name)
	local replaced_name, replaced_id
	head, replaced_name = head:gsub('(%sname%s*=%s*)"[^"]*"', function(prefix)
		return prefix .. '"' .. escape_attribute(name) .. '"'
	end, 1)
	head, replaced_id = head:gsub('(%sid%s*=%s*)"[^"]*"', "%1\"" .. id .. "\"", 1)
	if replaced_name ~= 1 or replaced_id ~= 1 then return nil, "the <keyboard> element could not be renamed" end
	return text:sub(1, open - 1) .. head .. text:sub(tag.next)
end

return M
