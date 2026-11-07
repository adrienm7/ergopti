--- tools/lib/layout_source_xkb.lua

--- ==============================================================================
--- MODULE: Layout Source XKB Export Adapter
--- DESCRIPTION:
--- Calls the existing canonical reader and pure XKB converter with explicit JSON
--- input. It reads no layout, registry or converter assets from implicit paths and
--- writes no files: the caller owns source admission and artifact publication.
--- ==============================================================================

if #arg ~= 1 then error("usage: lua layout_source_xkb.lua <shared root>", 0) end
package.path = arg[1] .. "/lua/?.lua;" .. arg[1] .. "/lua/?/init.lua;" .. package.path
local Json = require("json")
local Keylayout = require("layouts.keylayout")
local Converter = require("layouts.xkb_converter")

local function export()
	local input = assert(Json.decode(io.read("*a")))
	local admitted, refusal = Keylayout.admit_conversion_source(input.xml)
	if not admitted then return { ok = false, reason = "unsupported_keylayout:" .. refusal } end
	local canonical, reason = Keylayout.parse(input.xml)
	if not canonical then return { ok = false, reason = "keylayout_parse:" .. tostring(reason) } end
	-- The permissive canonical reader retains unresolved references. Conversion
	-- must not turn those into an apparently intentional empty character cell.
	local sets, actions = {}, {}
	for _, set in ipairs(canonical.key_map_sets) do
		sets[set.id] = {}
		for _, map in ipairs(set.key_maps) do sets[set.id][map.index] = map end
	end
	for _, action in ipairs(canonical.actions) do actions[action.id] = true end
	local root = sets[canonical.map_set]
	if not root[canonical.default_index] then return { ok = false, reason = "undefined_default_keymap" } end
	for _, select in ipairs(canonical.selects) do
		if not root[select.index] then return { ok = false, reason = "undefined_selected_keymap", index = select.index } end
	end
	for _, maps in pairs(sets) do
		for _, map in pairs(maps) do
			if map.base and (not sets[map.base.set] or not sets[map.base.set][map.base.index]) then return { ok = false, reason = "undefined_base_keymap" } end
			for _, key in ipairs(map.keys) do
				if key.action and not actions[key.action] then return { ok = false, reason = "undefined_key_action", action = key.action } end
			end
		end
	end
	local codes, code_error = Converter.keycodes(input.keycodes, input.convention)
	if not codes then return { ok = false, reason = code_error } end
	local placed, untouched = {}, {}
	for _, row in ipairs(codes) do placed[row[2]] = true end
	local function control(text)
		return text and (text:find("[%z\1-\31\127]") or text:find("\194[\128-\159]"))
	end
	for _, set in ipairs(canonical.key_map_sets) do
		for _, map in ipairs(set.key_maps) do
			for _, key in ipairs(map.keys) do
				if not placed[key.code] then untouched[key.code] = true
				elseif control(key.output) then return { ok = false, reason = "control_output_on_character_key", code = key.code } end
			end
		end
	end
	for _, action in ipairs(canonical.actions) do
		if control(action.id) then return { ok = false, reason = "control_action_identifier" } end
		local neutral = false
		for _, when in ipairs(action.whens) do
			if when.state == "none" then neutral = true end
			if control(when.state) or control(when.next) then return { ok = false, reason = "control_state_identifier" } end
			if control(when.output) then return { ok = false, reason = "control_output_in_action", action = action.id } end
		end
		if not neutral then return { ok = false, reason = "action_without_neutral_transition", action = action.id } end
	end
	for _, terminator in ipairs(canonical.terminators) do
		if control(terminator.state) then return { ok = false, reason = "control_state_identifier" } end
		if control(terminator.output) then return { ok = false, reason = "control_terminator", state = terminator.state } end
	end
	local projection = Converter.projection_report(canonical, codes, input.types)
	for _, action in ipairs(projection.unbound_actions) do
		-- A one-scalar action ID has a defined Unicode keysym fallback. Arbitrary
		-- identifiers would be emitted as raw, possibly nonexistent keysyms.
		if utf8.len(action) ~= 1 then return { ok = false, reason = "unbound_stateful_actions", actions = Json.array(projection.unbound_actions) } end
	end
	local result, conversion_error = Converter.convert(canonical, {
		keycodes = codes, keysyms = input.keysyms, locale_extended_prefixes = input.locale_extended_prefixes,
		template = input.template, layout_id = input.layout_id, display_name = input.display_name,
	})
	if not result then return { ok = false, reason = "xkb_conversion:" .. tostring(conversion_error) } end
	if #result.conflicts > 0 then return { ok = false, reason = "compose_conflicts", conflicts = result.conflicts } end
	if #result.unplaced > 0 then return { ok = false, reason = "unplaced_character_keys", codes = result.unplaced } end
	local passthrough = {}
	for code in pairs(untouched) do passthrough[#passthrough + 1] = code end
	table.sort(passthrough)
	for index, level in ipairs(projection.source_levels) do projection.source_levels[index] = Json.array(level) end
	for _, difference in ipairs(projection.modifier_differences) do
		difference.modifiers = Json.array(difference.modifiers)
		difference.key_codes = Json.array(difference.key_codes)
	end
	for _, cells in ipairs(projection.empty_cells) do cells.key_codes = Json.array(cells.key_codes) end
	projection.source_levels = Json.array(projection.source_levels)
	projection.modifier_differences = Json.array(projection.modifier_differences)
	projection.empty_cells = Json.array(projection.empty_cells)
	projection.unbound_actions = Json.array(projection.unbound_actions)
	return { ok = true, symbols = result.symbols_text, compose = result.compose_text,
		projection = projection, system_key_codes = Json.array(passthrough) }
end

local called, result = pcall(export)
if not called then
	io.stderr:write(tostring(result), "\n")
	os.exit(2)
end
io.write(Json.encode(result))
