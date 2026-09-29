--- _shared/lua/hotstrings/scope_overrides.lua

--- ==============================================================================
--- MODULE: Hotstring Scope Override Planner (Shared)
--- DESCRIPTION:
--- Plans what the Hotstrings « restore recommended » and « clear » scope changes
--- in the user's override file, the second file beside config.toml that holds
--- per-category and per-section delays, colours, previews and priorities.
---
--- WHY DELETION IS NOT ENOUGH FOR « RESTORE RECOMMENDED »:
--- Removing a user's delay makes the section inherit its corpus value
--- ([_meta.section_delays], then [_meta].delay, then the shared default). The
--- manifest's recommended delay is a separate declaration and the two differ:
--- autocorrection.toml ships `delay = 1.0` while the manifest recommends 0.5 s
--- for its caps section. Each driver therefore supplies its own runtime
--- inheritance, and this planner writes an explicit value wherever deletion
--- would not produce the recommendation. « Clear » only deletes, which leaves
--- every section on its corpus inheritance.
---
--- WHAT IS NEVER TOUCHED:
--- Categories, sections and fields this planner is not told about stay in the
--- file: sibling drivers share it, and a user may keep entries for packs that
--- are not installed on this machine.
--- ==============================================================================

local M = {}
local Languages = require("hotstrings.languages")
local KeyPath = require("toml_codec.key_path")

--- Override fields owned by the scope, in the order every driver writes them.
M.FIELDS = { "delay", "color", "show_tooltip", "priority" }

--- Whether a value is a dense array of non-empty strings.
--- @param segments any
--- @return boolean
local function valid_segments(segments)
	if type(segments) ~= "table" or #segments == 0 then return false end
	local count = 0
	for index, segment in pairs(segments) do
		if type(index) ~= "number" or type(segment) ~= "string" or segment == "" then return false end
		count = count + 1
	end
	return count == #segments
end

--- Copies a segment array so a caller cannot alias the planned identity.
--- @param segments table
--- @return table
local function copy_segments(segments)
	local copy = {}
	for index, segment in ipairs(segments) do copy[index] = segment end
	return copy
end

--- Plans the override changes of one Hotstrings scope operation.
--- @param request table
---   mode string "recommended" or "clear".
---   features table The generated manifest's `features` array.
---   groups table Dense array of runtime-owned groups: { id = string,
---     override = segments (the group's override table path),
---     sections = { section names }, bundled = boolean }.
---   inherited function (group_id, section) -> seconds the runtime resolves
---     for that section once every user override is removed.
---   extra table|nil Dense array of { override = segments, fields = names }
---     for scope-owned tables outside the catalogue (the global default delay).
--- @return table changes Dense array of `{ override, section, field, value }`;
---   a nil value removes the field, a number writes an explicit delay.
--- @return table recommendations Dense array of `{ group, section, seconds, inherited }`
---   for each delay written explicitly because inheritance differs.
function M.plan(request)
	assert(type(request) == "table", "override scope plan requires a request")
	assert(request.mode == "recommended" or request.mode == "clear", "unknown override scope mode")
	assert(type(request.features) == "table", "override scope plan requires the manifest features")
	assert(type(request.groups) == "table", "override scope plan requires the runtime group inventory")
	assert(type(request.inherited) == "function", "override scope plan requires the runtime inheritance")
	local changes, positions, recommendations = {}, {}, {}
	local function emit(override, section, field)
		local segments = copy_segments(override)
		if section then segments[#segments + 1] = section end
		local identity = KeyPath.render(segments):lower() .. "\0" .. field
		if positions[identity] then return positions[identity] end
		changes[#changes + 1] = { override = copy_segments(override), section = section, field = field }
		positions[identity] = #changes
		return #changes
	end
	local seen = {}
	for position, group in ipairs(request.groups) do
		assert(type(group) == "table" and type(group.id) == "string" and group.id ~= ""
			and valid_segments(group.override) and type(group.sections) == "table"
			and type(group.bundled) == "boolean", "override scope group is malformed at " .. position)
		assert(not seen[group.id], "override scope group is duplicated: " .. group.id)
		seen[group.id] = true
		for _, field in ipairs(M.FIELDS) do emit(group.override, nil, field) end
		for _, section in ipairs(group.sections) do
			assert(type(section) == "string" and section ~= "", "override scope section is malformed in " .. group.id)
			local delay_change
			for _, field in ipairs(M.FIELDS) do
				local index = emit(group.override, section, field)
				if field == "delay" then delay_change = changes[index] end
			end
			-- Personal and extension packs are user content: the manifest carries
			-- no recommendation for them, whatever their section names happen to be.
			local entry = group.bundled and Languages.section_feature(request.features, group.id, section) or nil
			local seconds = entry and type(entry.recommended) == "table" and entry.recommended.time_activation_seconds or nil
			if request.mode == "recommended" and seconds ~= nil then
				assert(type(seconds) == "number" and seconds >= 0, "manifest recommended delay is invalid for " .. entry.path)
				local inherited = request.inherited(group.id, section)
				assert(type(inherited) == "number", "runtime inheritance is unavailable for " .. group.id .. "." .. section)
				if inherited ~= seconds then
					delay_change.value = seconds
					recommendations[#recommendations + 1] = { group = group.id, section = section,
						seconds = seconds, inherited = inherited }
				end
			end
		end
	end
	for position, extra in ipairs(request.extra or {}) do
		assert(type(extra) == "table" and valid_segments(extra.override) and type(extra.fields) == "table"
			and #extra.fields > 0, "override scope extra table is malformed at " .. position)
		for _, field in ipairs(extra.fields) do
			assert(type(field) == "string" and field ~= "", "override scope extra field is malformed")
			emit(extra.override, nil, field)
		end
	end
	return changes, recommendations
end

--- Renders planned changes as shared TOML writer rows.
--- @param changes table Result of M.plan().
--- @return table rows `{ section, key, delete = true }` or `{ section, key, value }`.
function M.writer_rows(changes)
	assert(type(changes) == "table", "override scope rows require planned changes")
	local rows = {}
	for index, change in ipairs(changes) do
		assert(type(change) == "table" and valid_segments(change.override) and type(change.field) == "string",
			"override scope change is malformed at " .. index)
		local segments = copy_segments(change.override)
		if change.section ~= nil then segments[#segments + 1] = change.section end
		local section = KeyPath.render(segments)
		if change.value == nil then
			rows[index] = { section = section, key = change.field, delete = true }
		else
			rows[index] = { section = section, key = change.field, value = change.value }
		end
	end
	return rows
end

return M
