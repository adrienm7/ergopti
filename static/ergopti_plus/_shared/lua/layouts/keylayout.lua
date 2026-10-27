--- _shared/lua/layouts/keylayout.lua

--- ==============================================================================
--- MODULE: Keylayout Parser (Shared)
--- DESCRIPTION:
--- Reads the text of a macOS .keylayout into the CANONICAL parsed form every
--- driver and tool agrees on, so the XKB converter, the macOS and Linux managers
--- and the web composer stop owning one reader each.
---
--- The canonical form (schema 1) is plain data, ordered wherever the file's
--- order matters, and carries only what a conversion reads. Absent fields are
--- omitted, never null:
---
---   {
---     schema = 1,
---     name = "keyboard name",
---     map_set = "id of the default keyMapSet",
---     default_index = 0,                    -- keyMap used when no select matches
---     selects = {                           -- the default layout's modifierMap
---       { index = 1, modifiers = {          -- first match wins
---           { required = {"shift"}, optional = {"caps"} } } },   -- sorted tokens
---     },
---     key_map_sets = {
---       { id = "set", key_maps = {
---           { index = 0, base = { set = "set", index = 0 },     -- baseMapSet chain
---             keys = { { code = 0, output = "a" },              -- first <key> of a code wins
---                      { code = 1, action = "a_acute" } } } } },
---     },
---     actions = { { id = "a_acute", whens = {
---         { state = "none", output = "a", next = "s1" } } } },  -- state defaults to "none"
---     terminators = { { state = "s1", output = "^" } },
---   }
---
--- Modifier tokens are folded onto shift, option, control, command and caps
--- (left/right/any variants are not told apart). Duplicate elements keep the
--- first one, except a repeated baseIndex and a repeated modifierMap id, which
--- the later definition replaces, as the reader this schema was derived from
--- (keylayout_to_xkb.py) behaves. static/ergopti/linux/xkb_generation reads this
--- same form (Keylayout.from_canonical) and the AutoHotkey parser and the web
--- composer replay the corpus in _shared/tests/corpus/keylayout.
---
--- FEATURES & RATIONALE:
--- 1. PURE Lua: no driver imports, no io. The caller reads the file.
--- 2. Fail fast: a missing default layout, an undefined keyMapSet or modifierMap,
---    or an unknown modifier token is an error, never a silent default.
--- 3. Works on LuaJIT and Lua 5.4: entity decoding writes UTF-8 itself.
--- ==============================================================================

local M = {}

M.SCHEMA = 1

-- modifierMap tokens (Apple TN2056) folded onto the five modifiers a conversion
-- distinguishes.
local MODIFIER_TOKENS = {
	shift = "shift", rightShift = "shift", anyShift = "shift",
	option = "option", rightOption = "option", anyOption = "option",
	control = "control", rightControl = "control", anyControl = "control",
	command = "command",
	caps = "caps",
}

local NAMED_ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }





-- ====================================
-- ====================================
-- ======= 1/ Text Helpers ============
-- ====================================
-- ====================================

--- Encodes one code point as UTF-8.
--- @param cp number
--- @return string
local function utf8_char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40) end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

--- Decodes the XML character references a .keylayout attribute can hold.
--- @param value string
--- @return string
local function decode_entities(value)
	return (value:gsub("&(#?x?[%w]+);", function(token)
		if token:sub(1, 2) == "#x" and token:sub(3):match("^%x+$") then return utf8_char(tonumber(token:sub(3), 16)) end
		if token:sub(1, 1) == "#" and token:sub(2):match("^%d+$") then return utf8_char(tonumber(token:sub(2))) end
		return NAMED_ENTITIES[token]
	end))
end

--- Removes every `<!-- ... -->` comment; an unterminated one stays.
--- @param text string
--- @return string
local function strip_comments(text)
	local out, pos = {}, 1
	while true do
		local open = text:find("<!--", pos, true)
		if not open then break end
		local close = text:find("-->", open + 4, true)
		if not close then break end
		out[#out + 1] = text:sub(pos, open - 1)
		pos = close + 3
	end
	out[#out + 1] = text:sub(pos)
	return table.concat(out)
end

--- Matches one element tag at `at` (the position of a "<"), the way
--- `</?Name (attr="v")* /?>` reads; nil when the text there is not such a tag.
--- @param text string
--- @param at number
--- @return table|nil tag { closing, name, attrs, self_closing, next }
local function match_tag(text, at)
	local pos = at + 1
	local closing = false
	if text:sub(pos, pos) == "/" then closing = true; pos = pos + 1 end
	local name = text:match("^[A-Za-z][A-Za-z0-9]*", pos)
	if not name then return nil end
	pos = pos + #name
	local attrs = {}
	while true do
		local space = text:match("^%s+", pos)
		if not space then break end
		local after_space = pos + #space
		local attr = text:match("^[A-Za-z_:][%w_:.%-]*", after_space)
		if not attr then break end
		local cursor = after_space + #attr
		local equals = text:match("^%s*=%s*\"", cursor)
		if not equals then break end
		local value_start = cursor + #equals
		local value_end = text:find('"', value_start, true)
		if not value_end then break end
		attrs[#attrs + 1] = { attr, decode_entities(text:sub(value_start, value_end - 1)) }
		pos = value_end + 1
	end
	pos = pos + #(text:match("^%s*", pos))
	local self_closing = false
	if text:sub(pos, pos) == "/" then self_closing = true; pos = pos + 1 end
	if text:sub(pos, pos) ~= ">" then return nil end
	local map = {}
	for _, pair in ipairs(attrs) do map[pair[1]] = pair[2] end
	return { closing = closing, name = name, attrs = map, self_closing = self_closing, next = pos + 1 }
end

--- Parses a modifier `keys` attribute into sorted required and optional tokens.
--- @param keys string
--- @return table|nil entry { required, optional }
--- @return string|nil err
local function parse_modifier_keys(keys)
	local required, optional = {}, {}
	for token in keys:gmatch("%S+") do
		local is_optional = token:sub(-1) == "?"
		local name = is_optional and token:sub(1, -2) or token
		local folded = MODIFIER_TOKENS[name]
		if not folded then return nil, "unknown modifier token '" .. token .. "'" end
		if is_optional then optional[folded] = true else required[folded] = true end
	end
	local function sorted(set, minus)
		local out = {}
		for token in pairs(set) do
			if not (minus and minus[token]) then out[#out + 1] = token end
		end
		table.sort(out)
		return out
	end
	return { required = sorted(required), optional = sorted(optional, required) }
end





-- ====================================
-- ====================================
-- ======= 2/ Parser ==================
-- ====================================
-- ====================================

--- Parses the text of a .keylayout into the canonical form.
--- @param text string The file's text (UTF-8).
--- @return table|nil canonical
--- @return string|nil err The reason it cannot be read.
function M.parse(text)
	if type(text) ~= "string" then return nil, "keylayout text must be a string" end
	local body = strip_comments(text)
	local name = ""
	local layouts = {}
	local modifier_maps = {} -- id -> { default_index, selects }
	local sets, set_order = {}, {} -- id -> { order = {index...}, maps = { [index] = { keys, key_order, base } } }
	local actions, action_order = {}, {}
	local terminators, terminator_order = {}, {}

	local current_modifier_map, current_select, current_set, current_map, current_action
	local in_terminators = false

	local pos = 1
	while true do
		local open = body:find("<", pos, true)
		if not open then break end
		local tag = match_tag(body, open)
		if not tag then
			pos = open + 1
		else
			pos = tag.next
			local attrs, kind = tag.attrs, tag.name
			if tag.closing then
				if kind == "modifierMap" then current_modifier_map = nil
				elseif kind == "keyMapSelect" then current_select = nil
				elseif kind == "keyMapSet" then current_set = nil
				elseif kind == "keyMap" then current_map = nil
				elseif kind == "action" then current_action = nil
				elseif kind == "terminators" then in_terminators = false
				end
			elseif kind == "keyboard" then
				name = attrs.name or ""
			elseif kind == "layout" then
				layouts[#layouts + 1] = attrs
			elseif kind == "modifierMap" then
				if not attrs.id then return nil, "modifierMap without id" end
				current_modifier_map = attrs.id
				modifier_maps[current_modifier_map] = { default_index = tonumber(attrs.defaultIndex or "0"), selects = {} }
			elseif kind == "keyMapSelect" and current_modifier_map ~= nil then
				if not tonumber(attrs.mapIndex) then return nil, "keyMapSelect without mapIndex" end
				current_select = { index = tonumber(attrs.mapIndex), modifiers = {} }
				local selects = modifier_maps[current_modifier_map].selects
				selects[#selects + 1] = current_select
			elseif kind == "modifier" and current_select ~= nil then
				local entry, err = parse_modifier_keys(attrs.keys or "")
				if not entry then return nil, err end
				current_select.modifiers[#current_select.modifiers + 1] = entry
			elseif kind == "keyMapSet" then
				if not attrs.id then return nil, "keyMapSet without id" end
				current_set = attrs.id
				if not sets[current_set] then
					sets[current_set] = { maps = {}, order = {} }
					set_order[#set_order + 1] = current_set
				end
			elseif kind == "keyMap" and current_set ~= nil then
				local index = tonumber(attrs.index)
				if not index then return nil, "keyMap without index" end
				local set = sets[current_set]
				if not set.maps[index] then
					set.maps[index] = { keys = {}, order = {} }
					set.order[#set.order + 1] = index
				end
				current_map = set.maps[index]
				if attrs.baseIndex ~= nil then
					local base_index = tonumber(attrs.baseIndex)
					if not base_index then return nil, "keyMap with a non-numeric baseIndex" end
					current_map.base = { set = attrs.baseMapSet or current_set, index = base_index }
				end
				if tag.self_closing then current_map = nil end
			elseif kind == "key" and current_set ~= nil and current_map ~= nil then
				local code = tonumber(attrs.code)
				if not code then return nil, "key without code" end
				if current_map.keys[code] == nil then
					if attrs.output ~= nil then
						current_map.keys[code] = { code = code, output = attrs.output }
						current_map.order[#current_map.order + 1] = code
					elseif attrs.action ~= nil then
						current_map.keys[code] = { code = code, action = attrs.action }
						current_map.order[#current_map.order + 1] = code
					end
				end
			elseif kind == "action" then
				if not attrs.id then return nil, "action without id" end
				if actions[attrs.id] then
					current_action = { whens = {}, order = {}, discarded = true }
				else
					current_action = { id = attrs.id, whens = {}, order = {} }
					actions[attrs.id] = current_action
					action_order[#action_order + 1] = attrs.id
				end
				if tag.self_closing then current_action = nil end
			elseif kind == "when" and current_action ~= nil then
				local state = attrs.state or "none"
				if current_action.whens[state] == nil then
					local output = attrs.output
					current_action.whens[state] = { state = state, output = (output ~= nil and output ~= "") and output or nil, next = attrs.next }
					current_action.order[#current_action.order + 1] = state
				end
			elseif kind == "when" and in_terminators then
				if attrs.state ~= nil and terminators[attrs.state] == nil then
					terminators[attrs.state] = attrs.output or ""
					terminator_order[#terminator_order + 1] = attrs.state
				end
			elseif kind == "terminators" then
				in_terminators = true
			end
		end
	end

	local default_layout
	for _, item in ipairs(layouts) do
		if item.first == "0" then default_layout = item; break end
	end
	if not default_layout then return nil, 'no <layout first="0"> element' end
	local map_set = default_layout.mapSet or ""
	local modifiers_id = default_layout.modifiers or ""
	if not sets[map_set] then return nil, "keyMapSet '" .. map_set .. "' is not defined" end
	if not modifier_maps[modifiers_id] then return nil, "modifierMap '" .. modifiers_id .. "' is not defined" end

	local out = {
		schema = M.SCHEMA,
		name = name,
		map_set = map_set,
		default_index = modifier_maps[modifiers_id].default_index,
		selects = modifier_maps[modifiers_id].selects,
		key_map_sets = {},
		actions = {},
		terminators = {},
	}
	for _, id in ipairs(set_order) do
		local set = sets[id]
		local key_maps = {}
		for _, index in ipairs(set.order) do
			local map = set.maps[index]
			local keys = {}
			for _, code in ipairs(map.order) do keys[#keys + 1] = map.keys[code] end
			key_maps[#key_maps + 1] = { index = index, base = map.base, keys = keys }
		end
		out.key_map_sets[#out.key_map_sets + 1] = { id = id, key_maps = key_maps }
	end
	for _, id in ipairs(action_order) do
		local whens = {}
		for _, state in ipairs(actions[id].order) do whens[#whens + 1] = actions[id].whens[state] end
		out.actions[#out.actions + 1] = { id = id, whens = whens }
	end
	for _, state in ipairs(terminator_order) do
		out.terminators[#out.terminators + 1] = { state = state, output = terminators[state] }
	end
	return out
end

return M
