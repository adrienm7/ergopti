--- _shared/layouts/engine/composer/source_export.lua

--- ==============================================================================
--- MODULE: Layout Source Export Adapter (Shared)
--- DESCRIPTION:
--- The one admission and conversion step behind the Linux XKB and Windows KLC
--- exports of a layout source: the canonical reading of its .keylayout and the
--- XKB conversion with every check that refuses a construct before any file is
--- written. The repository tool (tools/lib/layout_source_export.lua, Lua 5.4)
--- and the layout editor page (layout_editor/lua_runner.js, fengari) call it
--- with the same explicit input, so both produce the same bytes.
---
--- FEATURES & RATIONALE:
--- 1. Pure: input is a table (the .keylayout text and the converter assets), the
---    result a table the caller encodes; no file, process or host access.
--- 2. Portable: runs unchanged under LuaJIT, Lua 5.4 and fengari (Lua 5.3);
---    UTF-8 lengths go through compat.utf8, which LuaJIT also has.
--- 3. Refusals return { ok = false, reason = ... } with stable reason codes the
---    tool and the page report as they are.
--- ==============================================================================

local Json      = require("core.text.engine.json")
local Utf8      = require("core.lifecycle.engine.compat.utf8")
local TableUtil = require("core.text.engine.table_util")
local Keylayout = require("layouts.engine.composer.keylayout")
local Converter = require("layouts.engine.composer.xkb_converter")

local M = {}

--- Reads a .keylayout through the shared conversion admission.
--- @param input table { xml = string }
--- @return table { ok = true, canonical = table } or { ok = false, reason = string }
function M.read(input)
	local canonical, reason = Keylayout.parse_conversion(input.xml)
	if not canonical then return { ok = false, reason = reason } end
	return { ok = true, canonical = canonical }
end

--- Converts a .keylayout into XKB symbols and XCompose text with its projection report.
--- @param input table { xml, convention, layout_id, display_name, keycodes, keysyms,
---   locale_extended_prefixes, template, types }
--- @return table { ok = true, symbols, compose, projection, system_key_codes } or { ok = false, reason, ... }
function M.xkb(input)
	local canonical, reason = Keylayout.parse_conversion(input.xml)
	if not canonical then return { ok = false, reason = reason } end
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
		if Utf8.len(action) ~= 1 then return { ok = false, reason = "unbound_stateful_actions", actions = Json.array(projection.unbound_actions) } end
	end
	local result, conversion_error = Converter.convert(canonical, {
		keycodes = codes, keysyms = input.keysyms, locale_extended_prefixes = input.locale_extended_prefixes,
		template = input.template, layout_id = input.layout_id, display_name = input.display_name,
	})
	if not result then return { ok = false, reason = "xkb_conversion_failed", detail = tostring(conversion_error) } end
	if #result.conflicts > 0 then return { ok = false, reason = "compose_conflicts", conflicts = result.conflicts } end
	if #result.unplaced > 0 then return { ok = false, reason = "unplaced_character_keys", codes = result.unplaced } end
	local passthrough = TableUtil.sorted_keys(untouched)
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

return M
