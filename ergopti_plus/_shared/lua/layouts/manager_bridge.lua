--- _shared/lua/layouts/manager_bridge.lua

--- ==============================================================================
--- MODULE: Layout Manager Bridge (Shared)
--- DESCRIPTION:
--- The part of hosting the layout manager page (_shared/ui/layout_manager)
--- that macOS and Linux do the same way: which messages the page may send,
--- what each one is allowed to touch, and the state pushed back after every
--- refresh and operation. The window itself (WKWebView, WebKitGTK) stays with
--- each driver; the Windows host applies the same rules in
--- windows/ui/layout_manager/init.ahk.
---
--- FEATURES & RATIONALE:
--- 1. Allowlist: a page message is an action of M.ACTIONS or nothing. Install
---    and update name a layout of the catalogue the page was shown; uninstall
---    and select an installed one; open_homepage only opens the https homepage
---    the catalogue gives for that layout, never a URL the page sends.
--- 2. One state shape for the three drivers:
---    { platform, index, source, error, installed, provided, builtin, active,
---      busy, result, record_error }, so the page decides the rows once.
--- 3. PURE Lua: the driver injects the layout registry client, the push to the
---    page, the strings, the URL opener and the window close.
--- ==============================================================================

local M = {}

--- The only actions the page may send (the page declares the same list).
M.ACTIONS = {
	ready = true,
	refresh = true,
	install = true,
	update = true,
	uninstall = true,
	select = true,
	open_homepage = true,
	close = true,
}

-- A registry id: the rule of tools/build/build-layouts-index.cjs.
local ID_PATTERN = "^[a-z][a-z0-9_]*$"





-- ========================
-- ========================
-- ======= 1/ State =======
-- ========================
-- ========================

--- The entry of an id in a decoded index, or nil.
--- @param index table|nil
--- @param id string
--- @return table|nil
local function index_entry(index, id)
	for _, entry in ipairs(type(index) == "table" and type(index.layouts) == "table" and index.layouts or {}) do
		if type(entry) == "table" and entry.id == id then return entry end
	end
	return nil
end

--- The state the page renders.
--- @param snapshot table The registry client's snapshot.
--- @param result table|nil The last operation's result.
--- @return table
function M.page_state(snapshot, result)
	return {
		platform = snapshot.platform,
		index = snapshot.index,
		source = snapshot.source,
		error = snapshot.error,
		installed = snapshot.installed or {},
		provided = snapshot.provided or {},
		builtin = snapshot.builtin or {},
		active = snapshot.active or "",
		busy = snapshot.busy,
		result = result,
		record_error = snapshot.record_error,
	}
end





-- =============================
-- =============================
-- ======= 2/ Controller =======
-- =============================
-- =============================

--- Creates the controller of one page.
--- deps.registry: { refresh(on_done), snapshot(), install(id, on_done),
---   uninstall(id, on_done), select(id, on_done) }; on_done(ok, detail_or_code, detail).
--- deps.push(function_name, payload) evaluates window.<function_name>(payload).
--- deps.strings() returns the translated strings the page shows.
--- deps.open_url(url) opens an https URL; deps.close() closes the window.
--- deps.log(level, message, ...) logs through the driver's logger.
--- @param deps table
--- @return table controller { on_message(payload) -> handled }
function M.new(deps)
	local controller = { result = nil }

	local function push_state()
		return deps.push("updateState", M.page_state(deps.registry.snapshot(), controller.result))
	end

	local function operation_done(id, action)
		return function(ok, detail_or_code, detail)
			if ok then
				local warning = type(detail_or_code) == "table" and detail_or_code.enabled == false and "not_enabled" or nil
				controller.result = { id = id, action = action, ok = true, warning = warning }
			else
				controller.result = { id = id, action = action, ok = false, code = tostring(detail_or_code),
					detail = detail ~= nil and tostring(detail) or nil }
			end
			push_state()
		end
	end

	--- Handles one message from the page.
	--- @param payload any Decoded message.
	--- @return boolean handled False for anything outside the allowlist.
	function controller.on_message(payload)
		if type(payload) ~= "table" or type(payload.action) ~= "string" or not M.ACTIONS[payload.action] then
			deps.log("warn", "Refused a layout manager message outside the allowlist.")
			return false
		end
		local action, id = payload.action, payload.id
		if action == "ready" then
			controller.result = nil
			deps.push("initData", { strings = deps.strings(),
				state = M.page_state(deps.registry.snapshot(), nil) })
			deps.registry.refresh(function() push_state() end)
			return true
		end
		if action == "refresh" then
			deps.registry.refresh(function() push_state() end)
			return true
		end
		if action == "close" then
			deps.close()
			return true
		end
		if type(id) ~= "string" or not id:match(ID_PATTERN) then
			deps.log("warn", "Refused a layout manager '%s' without a valid layout id.", action)
			return false
		end
		local snapshot = deps.registry.snapshot()
		if action == "open_homepage" then
			local entry = index_entry(snapshot.index, id) or (snapshot.installed or {})[id]
			local homepage = type(entry) == "table" and entry.homepage or nil
			if type(homepage) ~= "string" or not homepage:match("^https://[^%s]+$") then
				deps.log("warn", "Refused to open the homepage of '%s': none is published over https.", id)
				return false
			end
			deps.open_url(homepage)
			return true
		end
		if action == "install" or action == "update" then
			if not index_entry(snapshot.index, id) then
				deps.log("warn", "Refused to %s '%s': the catalogue does not list it.", action, id)
				return false
			end
			deps.registry.install(id, operation_done(id, action))
			push_state()
			return true
		end
		if not (snapshot.installed or {})[id] then
			deps.log("warn", "Refused to %s '%s': it is not installed.", action, id)
			return false
		end
		if action == "uninstall" then
			deps.registry.uninstall(id, operation_done(id, action))
		else
			deps.registry.select(id, operation_done(id, action))
		end
		push_state()
		return true
	end

	return controller
end

return M
