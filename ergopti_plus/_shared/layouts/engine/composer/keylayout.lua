--- _shared/layouts/engine/composer/keylayout.lua

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

--- Keeps hexadecimal integer text from wrapping through Lua 5.4's signed domain.
--- Decimal and floating-point syntax retain the reader's existing number grammar.
local function exact_number(value)
	if type(value) == "string" then
		local sign, digits = value:match("^%s*([+-]?)0[xX]([%da-fA-F]+)%s*$")
		if digits then
			digits = digits:gsub("^0+", ""):upper()
			if digits == "" then digits = "0" end
			local limit = sign == "-" and "8000000000000000" or "7FFFFFFFFFFFFFFF"
			if #digits > #limit or (#digits == #limit and digits > limit) then return nil end
		end
	end
	return tonumber(value)
end

--- Validates before conversion so an oversized hexadecimal entity cannot alias.
local function entity_scalar(digits, base)
	local significant = digits:gsub("^0+", ""):upper()
	if significant == "" then significant = "0" end
	local limit = base == 16 and "10FFFF" or "1114111"
	if #significant > #limit or (#significant == #limit and significant > limit) then
		error("numeric character reference is outside the supported Unicode scalar domain", 0)
	end
	local cp = tonumber(significant, base)
	if cp >= 0xD800 and cp <= 0xDFFF then
		error("numeric character reference is outside the supported Unicode scalar domain", 0)
	end
	return cp
end

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
		if token:sub(1, 2) == "#x" and token:sub(3):match("^%x+$") then return utf8_char(entity_scalar(token:sub(3), 16)) end
		if token:sub(1, 1) == "#" and token:sub(2):match("^%d+$") then return utf8_char(entity_scalar(token:sub(2), 10)) end
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
--- `</?Name (attr="v" | attr='v')* /?>` reads; nil when the text there is not such a tag.
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
		-- XML lets an attribute value sit in double or single quotes.
		local equals = text:match("^%s*=%s*[\"']", cursor)
		if not equals then break end
		local quote = equals:sub(-1)
		local value_start = cursor + #equals
		local value_end = text:find(quote, value_start, true)
		if not value_end then break end
		attrs[#attrs + 1] = { attr, decode_entities(text:sub(value_start, value_end - 1)) }
		pos = value_end + 1
	end
	pos = pos + #(text:match("^%s*", pos))
	local self_closing = false
	if text:sub(pos, pos) == "/" then self_closing = true; pos = pos + 1 end
	if text:sub(pos, pos) ~= ">" then return nil end
	local map, duplicate = {}, nil
	for _, pair in ipairs(attrs) do
		if map[pair[1]] ~= nil then duplicate = pair[1] end
		map[pair[1]] = pair[2]
	end
	return { closing = closing, name = name, attrs = map, duplicate_attribute = duplicate, self_closing = self_closing, next = pos + 1 }
end

-- The elements a conversion reads. A tag of one of them that match_tag cannot
-- read is refused: skipping it silently dropped keys or whole keyMaps. Twin of
-- _KNOWN_ELEMENTS in keylayout_to_xkb.py.
local KNOWN_ELEMENTS = {
	keyboard = true, layouts = true, layout = true, modifierMap = true, keyMapSelect = true, modifier = true,
	keyMapSet = true, keyMap = true, key = true, actions = true, action = true, when = true, terminators = true,
}

--- Whether the text at `at` (a "<") opens a tag of a known element.
--- @param text string
--- @param at number
--- @return boolean
local function known_tag_start(text, at)
	local name = text:match("^</?([A-Za-z][A-Za-z0-9]*)[%s/>]", at)
	return name ~= nil and KNOWN_ELEMENTS[name] == true
end

-- The text helpers a .keylayout editor shares with this reader
-- (layouts/engine/composer/keylayout_rows.lua), so both read a tag the same way.
M.strip_comments = strip_comments
M.match_tag = match_tag

-- The preservation exporter keeps everything, but the conversion form above
-- intentionally projects part of Apple's format. A native source export must
-- refuse constructs that disappear before the target converter can report them.
local CONVERSION_ATTRIBUTES = {
	keyboard = { group = true, id = true, name = true, maxout = true }, layouts = {},
	layout = { first = true, last = true, mapSet = true, modifiers = true },
	modifierMap = { id = true, defaultIndex = true }, keyMapSelect = { mapIndex = true }, modifier = { keys = true },
	keyMapSet = { id = true }, keyMap = { index = true, baseMapSet = true, baseIndex = true },
	key = { code = true, output = true, action = true }, actions = {}, action = { id = true },
	when = { state = true, output = true, next = true }, terminators = {},
}
local CONVERSION_PARENT = {
	keyboard = "", layouts = "keyboard", layout = "layouts", modifierMap = "keyboard", keyMapSelect = "modifierMap",
	modifier = "keyMapSelect", keyMapSet = "keyboard", keyMap = "keyMapSet", key = "keyMap",
	actions = "keyboard", action = "actions", when = { action = true, terminators = true }, terminators = "keyboard",
}
local CONVERSION_MODIFIERS = { anyShift = true, anyOption = true, anyControl = true, command = true, caps = true }
local CONVERSION_NUMBERS = { first = true, last = true, defaultIndex = true, mapIndex = true, index = true, baseIndex = true, code = true }

--- Refuses XML structure that the canonical conversion form cannot retain.
--- This is a deliberately narrow conversion subset, not a native DTD validator.
--- @param text string Original XML, before the lossy conversion projection.
--- @return boolean admitted
--- @return string|nil reason Stable path of the unsupported construct.
function M.admit_conversion_source(text)
	if type(text) ~= "string" then return false, "keylayout_text" end
	local body, stack, position, root_count = strip_comments(text), {}, 1, 0
	local counts = { layouts = 0, layout = 0, modifierMap = 0, actions = 0, terminators = 0 }
	while position <= #body do
		local open = body:find("<", position, true)
		local between = body:sub(position, open and open - 1 or #body):gsub("^\239\187\191", "")
		if between:find("%S") then return false, "xml_text_outside_attributes" end
		if not open then break end
		local declaration = body:match("^<%?xml%s.-%?>", open) or body:match("^<!DOCTYPE%s+keyboard%s+SYSTEM%s+[^>]+>", open)
		if declaration then
			if #stack > 0 or root_count > 0 then return false, "xml_declaration_position" end
			position = open + #declaration
		else
			local tag = match_tag(body, open)
			if not tag then return false, "xml_malformed_tag" end
			local allowed = CONVERSION_ATTRIBUTES[tag.name]
			if not allowed then return false, "element:" .. tag.name end
			if tag.duplicate_attribute then return false, "duplicate_attribute:" .. tag.name .. "." .. tag.duplicate_attribute end
			for attr in pairs(tag.attrs) do
				if not allowed[attr] or tag.closing then return false, "attribute:" .. tag.name .. "." .. attr end
				if CONVERSION_NUMBERS[attr] and (not tag.attrs[attr]:match("^%d+$") or tonumber(tag.attrs[attr]) > 2147483647) then return false, "numeric_attribute:" .. tag.name .. "." .. attr end
			end
			if tag.closing then
				if tag.self_closing then return false, "xml_self_closing_end_tag" end
				if not stack[#stack] or stack[#stack].name ~= tag.name then return false, "xml_unbalanced:" .. tag.name end
				table.remove(stack)
			else
				local parent = stack[#stack]
				local parent_name = parent and parent.name or ""
				local wanted = CONVERSION_PARENT[tag.name]
				if not (wanted == parent_name or type(wanted) == "table" and wanted[parent_name]) then return false, "parent:" .. tag.name end
				if tag.name == "keyboard" then root_count = root_count + 1; if root_count ~= 1 then return false, "multiple_keyboards" end end
				if counts[tag.name] ~= nil then counts[tag.name] = counts[tag.name] + 1; if counts[tag.name] > 1 then return false, "multiple_" .. tag.name end end
				local identity = tag.attrs.id or tag.attrs.index or tag.attrs.code or tag.attrs.state
				if tag.attrs.index or tag.attrs.code then identity = identity:gsub("^0+", ""); if identity == "" then identity = "0" end end
				if identity and parent then
					local token = tag.name .. ":" .. identity
					if parent.seen[token] then return false, "duplicate:" .. token end
					parent.seen[token] = true
				end
				if tag.name == "modifier" then
					for token in (tag.attrs.keys or ""):gmatch("%S+") do
						if not CONVERSION_MODIFIERS[token:gsub("%?$", "")] then return false, "modifier:" .. token end
					end
				elseif tag.name == "key" then
					if (tag.attrs.output ~= nil) == (tag.attrs.action ~= nil) then return false, "key_output_kind" end
				elseif tag.name == "keyMap" then
					if tag.attrs.baseMapSet and not tag.attrs.baseIndex then return false, "base_without_index" end
				elseif tag.name == "when" then
					if tag.attrs.state == nil then return false, "when_without_state" end
					if parent_name == "terminators" and tag.attrs.next then return false, "terminator_next" end
					if parent_name == "action" and (tag.attrs.output == "" or not tag.attrs.output and not tag.attrs.next or tag.attrs.next == "") then return false, "empty_action_transition" end
					if tag.attrs.next and tag.attrs.next ~= "" and tag.attrs.output and tag.attrs.output ~= "" then return false, "simultaneous_output_and_next" end
				end
				if not tag.self_closing then stack[#stack + 1] = { name = tag.name, seen = {} } end
			end
			position = tag.next
		end
	end
	if #stack ~= 0 or root_count ~= 1 then return false, "xml_incomplete" end
	return true
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
			if known_tag_start(body, open) then
				local _, newlines = body:sub(1, open):gsub("\n", "")
				return nil, "malformed tag on line " .. (newlines + 1) .. " of the comment-free text"
			end
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
				local default_index = exact_number(attrs.defaultIndex or "0")
				if not default_index then return nil, "modifierMap without a valid defaultIndex" end
				modifier_maps[current_modifier_map] = { default_index = default_index, selects = {} }
			elseif kind == "keyMapSelect" and current_modifier_map ~= nil then
				if not exact_number(attrs.mapIndex) then return nil, "keyMapSelect without mapIndex" end
				current_select = { index = exact_number(attrs.mapIndex), modifiers = {} }
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
				local index = exact_number(attrs.index)
				if not index then return nil, "keyMap without index" end
				local set = sets[current_set]
				if not set.maps[index] then
					set.maps[index] = { keys = {}, order = {} }
					set.order[#set.order + 1] = index
				end
				current_map = set.maps[index]
				if attrs.baseIndex ~= nil then
					local base_index = exact_number(attrs.baseIndex)
					if not base_index then return nil, "keyMap with a non-numeric baseIndex" end
					current_map.base = { set = attrs.baseMapSet or current_set, index = base_index }
				end
				if tag.self_closing then current_map = nil end
			elseif kind == "key" and current_set ~= nil and current_map ~= nil then
				local code = exact_number(attrs.code)
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


--- Reads the admitted native-conversion subset and rejects unresolved references.
--- The preservation reader remains permissive; converters must not turn missing
--- maps or actions into apparently intentional empty character cells.
--- @param text string Original XML.
--- @return table|nil canonical
--- @return string|nil reason Stable conversion refusal.
function M.parse_conversion(text)
	local admitted, refusal = M.admit_conversion_source(text)
	if not admitted then return nil, "unsupported_keylayout:" .. refusal end
	local canonical, reason = M.parse(text)
	if not canonical then return nil, "keylayout_parse:" .. tostring(reason) end
	return M.admit_canonical(canonical)
end

--- Rejects unresolved references in a canonical form, read from a file
--- (M.parse_conversion) or compiled straight from a layout source
--- (layout_composer/source_compiler.js compileCanonical).
--- @param canonical table Schema-1 form.
--- @return table|nil canonical
--- @return string|nil reason Stable conversion refusal.
function M.admit_canonical(canonical)
	if type(canonical) ~= "table" or canonical.schema ~= M.SCHEMA then return nil, "canonical_schema" end
	for _, field in ipairs({ "selects", "key_map_sets", "actions", "terminators" }) do
		if type(canonical[field]) ~= "table" then return nil, "canonical_field:" .. field end
	end
	local sets, actions = {}, {}
	for _, set in ipairs(canonical.key_map_sets) do
		sets[set.id] = {}
		for _, map in ipairs(set.key_maps) do sets[set.id][map.index] = map end
	end
	for _, action in ipairs(canonical.actions) do actions[action.id] = true end
	local root = sets[canonical.map_set]
	if not root then return nil, "undefined_keymap_set" end
	if not root[canonical.default_index] then return nil, "undefined_default_keymap" end
	for _, select in ipairs(canonical.selects) do
		if not root[select.index] then return nil, "undefined_selected_keymap:" .. select.index end
	end
	for _, maps in pairs(sets) do
		for _, map in pairs(maps) do
			if map.base and (not sets[map.base.set] or not sets[map.base.set][map.base.index]) then return nil, "undefined_base_keymap" end
			for _, key in ipairs(map.keys) do
				if key.action and not actions[key.action] then return nil, "undefined_key_action:" .. key.action end
			end
		end
	end
	for _, maps in pairs(sets) do
		for _, map in pairs(maps) do
			local seen, current = {}, map
			while current do
				if seen[current] then return nil, "cyclic_base_keymap" end
				seen[current] = true
				current = current.base and sets[current.base.set][current.base.index] or nil
			end
		end
	end
	return canonical
end





-- ====================================
-- ====================================
-- ======= 3/ Element Positions =======
-- ====================================
-- ====================================

--- Where the elements of a comment-free .keylayout text are, for an editor that
--- rewrites cells in place (layouts/engine/composer/keylayout_rows.lua): the editor reads values
--- through M.parse and positions through this, so tags are read in this module
--- only. Positions are byte offsets into `body`; `open_stop` is the first byte
--- after an opening tag, `close_start` the "<" of its closing tag and `stop` the
--- first byte after the whole element.
--- @param body string Comment-free text (M.strip_comments).
--- @return table|nil positions { default_modifiers, modifier_maps = { [id] = { open_stop,
---   self_closing } }, key_map_sets = { [id] = { open_stop, close_start, maps = { [index] =
---   { start, open_stop, close_start, stop, self_closing } } } } }
--- @return string|nil err
function M.positions(body)
	local out = { modifier_maps = {}, key_map_sets = {} }
	local pos, set, map = 1, nil, nil
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
				if kind == "keyMapSet" and set ~= nil then
					set.close_start, set = open, nil
				elseif kind == "keyMap" and map ~= nil then
					map.close_start, map.stop, map = open, tag.next, nil
				end
			elseif kind == "layout" and attrs.first == "0" and out.default_modifiers == nil then
				out.default_modifiers = attrs.modifiers
			elseif kind == "modifierMap" and attrs.id ~= nil then
				out.modifier_maps[attrs.id] = { open_stop = tag.next, self_closing = tag.self_closing }
			elseif kind == "keyMapSet" and attrs.id ~= nil then
				if out.key_map_sets[attrs.id] then return nil, "keyMapSet '" .. attrs.id .. "' is defined twice" end
				set = { open_stop = tag.next, maps = {} }
				out.key_map_sets[attrs.id] = set
				if tag.self_closing then set.close_start, set = tag.next, nil end
			elseif kind == "keyMap" and set ~= nil and exact_number(attrs.index) ~= nil then
				local index = exact_number(attrs.index)
				if set.maps[index] then return nil, "keyMap " .. index .. " is defined twice" end
				map = { start = open, open_stop = tag.next, self_closing = tag.self_closing }
				set.maps[index] = map
				if tag.self_closing then map.stop, map = tag.next, nil end
			end
		end
	end
	return out, nil
end

--- The <key> elements of a keyMap's content, in order.
--- @param content string The text between a keyMap's opening and closing tags.
--- @return table keys Array of { code, start, stop, self_closing }.
function M.key_positions(content)
	local keys, pos = {}, 1
	while true do
		local open = content:find("<", pos, true)
		if not open then break end
		local tag = match_tag(content, open)
		if not tag then
			pos = open + 1
		else
			pos = tag.next
			if tag.name == "key" and not tag.closing and exact_number(tag.attrs.code) ~= nil then
				keys[#keys + 1] = { code = exact_number(tag.attrs.code), start = open, stop = tag.next,
					self_closing = tag.self_closing }
			end
		end
	end
	return keys
end

return M
