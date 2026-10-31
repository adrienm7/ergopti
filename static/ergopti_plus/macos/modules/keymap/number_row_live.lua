--- modules/keymap/number_row_live.lua

--- ==============================================================================
--- MODULE: Number Row Options, Live (macOS)
--- DESCRIPTION:
--- Applies the stored number-row options (layout.direct_access_digits and
--- layout.number_row_reorder_edges) to the layout the user types with: the
--- installed .keylayout of that layout is rebuilt with the options and replaced
--- live, with no logout (modules/keymap/layout_rows_build.lua).
---
--- FEATURES & RATIONALE:
--- 1. The source is a layout of ours whose file the driver holds: an installed
---    registry layout or the composed one, selected now, or the build that
---    currently types for one of them. Any other input source (a system layout,
---    an Ergopti bundle typing its digits on both levels) has no source:
---    no_source_layout, and the choice stays stored and inert, as on Linux.
--- 2. The choice is stored by the caller first; this module only applies it,
---    so a refused application never loses the user's intent.
--- 3. Every collaborator is injectable (registry, build deps, active sources).
--- ==============================================================================

local Logger = require("infra.logger")

local M = {}

local LOG = "keymap.number_row_live"

--- The reason a choice cannot be applied now.
M.REASON_NO_SOURCE = "no_source_layout"

--- The collaborators, the production ones by default.
--- @param deps table|nil { registry, registry_deps, build, build_deps, active_sources }
--- @return table
local function resolve(deps)
	deps = deps or {}
	local build = deps.build or require("modules.keymap.layout_rows_build")
	return {
		registry = deps.registry or require("modules.keymap.layout_registry"),
		registry_deps = deps.registry_deps,
		build = build,
		build_deps = deps.build_deps or build.default_deps(),
		active_sources = deps.active_sources or require("modules.keymap.input_sources").list_active_keyboard_layouts,
	}
end

--- Whether an input-source record is the selected `name`.
--- @param record table { id, name, selected }
--- @param name string KeyboardLayout Name.
--- @return boolean
local function selects(record, name)
	if record.selected ~= true then return false end
	local suffix = "." .. name
	return record.name == name or record.id == name
		or (type(record.id) == "string" and record.id:sub(-#suffix) == suffix)
end

--- The layout the options apply to now.
--- @param deps table|nil
--- @return table|nil source { id, keyboard_name, text, convention }
--- @return string|nil reason M.REASON_NO_SOURCE, or why the source is unreadable.
function M.source(deps)
	local resolved = resolve(deps)
	local snapshot = resolved.registry.snapshot(resolved.registry_deps)
	local id = snapshot.active ~= "" and snapshot.active or nil
	if id == nil then
		local current = resolved.build.current(resolved.build_deps)
		local ok, records = pcall(resolved.active_sources)
		for _, record in ipairs(current and ok and type(records) == "table" and records or {}) do
			if selects(record, current.name) then id = current.source_id end
		end
	end
	local entry = id and (snapshot.installed or {})[id] or nil
	if entry == nil then return nil, M.REASON_NO_SOURCE end
	local text, read_err = resolved.registry.read_local_copy(id, resolved.registry_deps)
	if not text then return nil, read_err end
	return { id = id, keyboard_name = entry.keyboard_name, text = text, convention = entry.keycode_convention }, nil
end

--- Whether the options can be applied now.
--- @param deps table|nil
--- @return boolean available
--- @return string|nil reason
function M.available(deps)
	local source, reason = M.source(deps)
	return source ~= nil, reason
end

--- Applies stored options to the layout typing now.
--- @param rows table { order, edges } The stored choice.
--- @param on_done function on_done(applied, code, detail, result)
--- @param deps table|nil
--- @return boolean dispatched
function M.apply(rows, on_done, deps)
	local resolved = resolve(deps)
	local source, reason = M.source(deps)
	if not source then
		Logger.warn(LOG, "The number-row options are stored and not applied: %s.", tostring(reason))
		on_done(false, reason == M.REASON_NO_SOURCE and reason or "source_unreadable", reason, nil)
		return false
	end
	return resolved.build.replace(source, rows, function(ok, code_or_result, detail)
		if ok then return on_done(true, nil, nil, code_or_result) end
		on_done(false, code_or_result, detail, nil)
	end, resolved.build_deps)
end

return M
