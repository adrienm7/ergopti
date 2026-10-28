--- modules/keymap/number_row_live.lua

--- ==============================================================================
--- MODULE: Number Row Options, Live (Linux)
--- DESCRIPTION:
--- Stores the number-row options (ordering and edge keys) and applies them to the
--- keyboard layout of the running session through the layout manager
--- (layout_registry.apply_rows): the layout is converted again with the options,
--- installed in the user XKB tree and loaded into the running X server. A session
--- that cannot load a user layout live keeps the stored choice and says why.
---
--- FEATURES & RATIONALE:
--- 1. The choice is stored first and survives a refused application: the file is
---    the user's intent, the layout is its effect.
--- 2. One answer to « can the options be applied now »: a session that loads a
---    layout live and a layout of ours to apply them to.
--- 3. Every collaborator is injectable, so tests replay the flow without a
---    desktop, a Python child or a real configuration folder.
--- ==============================================================================

local M = {}

--- The collaborators of the module, resolved lazily so the tests may replace them.
--- @param deps table|nil { preferences, registry, session_type, notify }
--- @return table
local function resolve(deps)
	deps = deps or {}
	return {
		preferences = deps.preferences or require("infra.number_row_preferences"),
		registry = deps.registry or require("modules.keymap.layout_registry"),
		session_type = deps.session_type or function() return (os.getenv("XDG_SESSION_TYPE") or ""):lower() end,
		registry_deps = deps.registry_deps,
	}
end

--- Whether the running session loads a user layout live.
--- @param deps table|nil
--- @return boolean live
--- @return string session The session type declared ("" when none).
function M.session_supports_live(deps)
	local session = resolve(deps).session_type()
	return session == "x11", session
end

--- Whether the options can be applied now: a live session and a layout to apply them to.
--- @param deps table|nil
--- @return boolean available
--- @return string|nil reason "session_unsupported" or "no_source_layout".
function M.available(deps)
	local live = M.session_supports_live(deps)
	if not live then return false, "session_unsupported" end
	local resolved = resolve(deps)
	local snapshot = resolved.registry.snapshot(resolved.registry_deps)
	if require("table_util").count(snapshot.installed or {}) == 0 then return false, "no_source_layout" end
	return true, nil
end

--- The stored options.
--- @param deps table|nil
--- @return table { order, edges }
function M.stored(deps)
	return resolve(deps).preferences.settings()
end

--- Applies the stored options to the running session.
--- @param on_done function on_done(applied, code, detail, live_code, report)
--- @param deps table|nil
--- @return boolean dispatched
function M.apply_stored(on_done, deps)
	local resolved = resolve(deps)
	local rows = resolved.preferences.settings()
	return resolved.registry.apply_rows(nil, rows, function(ok, detail, extra, _, live_code)
		if ok then
			on_done(true, nil, nil, nil, detail.rows)
		else
			on_done(false, detail, extra, live_code, nil)
		end
	end, resolved.registry_deps)
end

--- Stores one option, then applies the stored options.
--- @param role string "order" or "edges".
--- @param value any
--- @param on_done function|nil on_done(applied, code, detail, live_code, report) once the application ends.
--- @param deps table|nil
--- @return boolean stored False when the choice could not be stored (nothing is applied).
function M.set(role, value, on_done, deps)
	local resolved = resolve(deps)
	if resolved.preferences.set(role, value) ~= true then return false end
	local available, reason = M.available(deps)
	if not available then
		if on_done then on_done(false, reason, nil, nil, nil) end
		return true
	end
	M.apply_stored(on_done or function() end, deps)
	return true
end

return M
