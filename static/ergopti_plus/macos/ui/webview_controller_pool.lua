--- ui/webview_controller_pool.lua

--- ==============================================================================
--- MODULE: Bounded WebView Usercontent Controllers
--- DESCRIPTION:
--- Native controllers retain their own userdata until Lua-state teardown. Reuse
--- one controller per admitted UI role while keeping each window's authority in
--- an opaque lease. Callback release never claims native userdata collection.
--- ==============================================================================

local M = {}
local ROLE_PORTS = {
	action_picker = "action_picker_bridge",
	layout_manager = "layout_manager_bridge",
	permission_dialog = "permission_dialog_bridge",
}
local LOG = "ui_builder"

--- Creates a pool owned by one UI module, without eagerly accessing native APIs.
--- @param native_new function Public native constructor accepting a port name.
--- @param Logger table Central diagnostic port.
--- @return table pool Exact controller and lease owner.
function M.new(native_new, Logger)
	assert(type(native_new) == "function", "Missing usercontent constructor")
	local api, entries = {}, {}
	local leases = setmetatable({}, { __mode = "k" })

	--- Removes the exact receiver and leaves a terminal token harmless to successors.
	--- @param lease table Private lease record.
	local function retire(lease)
		local entry = lease.entry
		if lease.view and entry.routes[lease.view] == lease then entry.routes[lease.view] = nil end
		entry.leases[lease.token] = nil
		if entry.pending == lease then entry.pending = nil end
		lease.receiver, lease.view, lease.released = nil, nil, true
	end

	--- Revokes business before attempting exact native callback retirement.
	--- @param token table Opaque lease token.
	--- @return boolean released, string|nil error Native acknowledgement result.
	function api.release(token)
		local lease = leases[token]
		if not lease then return false, "Unknown usercontent lease" end
		if lease.released then return true end
		lease.revoked, lease.receiver = true, nil
		local entry = lease.entry
		if lease.view and entry.routes[lease.view] == lease then entry.routes[lease.view] = nil end
		for other in pairs(entry.leases) do
			if other ~= token and entry.pending ~= lease then retire(lease); return true end
		end
		if entry.busy then return false, "Usercontent callback mutation remains active" end
		entry.pending, entry.busy = lease, true
		local ok, result = xpcall(function() return entry.controller:setCallback(nil) end, debug.traceback)
		entry.busy = false
		if not ok or not rawequal(result, entry.controller) then return false, tostring(result) end
		entry.bound = false
		retire(lease)
		return true
	end

	--- Reserves an independent window lease under a closed, module-owned UI role.
	--- @param role string Admitted UI role.
	--- @return table|nil token, userdata|table|string controller_or_error
	function api.reserve(role)
		local port = ROLE_PORTS[role]
		if not port then return nil, "Unknown usercontent role" end
		local entry = entries[role]
		if entry and entry.busy then return nil, "Usercontent callback mutation remains active" end
		if entry then
			local retry = {}
			for token, lease in pairs(entry.leases) do if lease.revoked then retry[#retry + 1] = token end end
			for _, token in ipairs(retry) do
				local released, detail = api.release(token)
				if not released then return nil, detail end
			end
		else
			entry = { leases = {}, routes = {}, busy = true }
			entries[role] = entry
			local ok, controller = xpcall(function() return native_new(port) end, debug.traceback)
			entry.busy = false
			if not ok or not controller then entries[role] = nil; return nil, tostring(controller) end
			entry.controller = controller
			entry.dispatch = function(message)
				if type(message) ~= "table" or rawget(message, "name") ~= port then return end
				local source = rawget(message, "webView")
				local lease = entry.routes[source]
				if not lease or not rawequal(source, lease.view) or lease.revoked or not lease.committed then return end
				local receiver = lease.receiver
				local delivered, detail = xpcall(function() receiver(message) end, debug.traceback)
				if not delivered then pcall(Logger.error, LOG, "WebView bridge delivery failed: %s.", tostring(detail)) end
			end
		end
		local token = setmetatable({}, { __metatable = false })
		local lease = { token = token, entry = entry }
		leases[token], entry.leases[token] = lease, lease
		return token, entry.controller
	end

	--- Binds business below an already retained lease, including partial native failure.
	--- @param token table Opaque lease token.
	--- @param receiver function Window-scoped receiver with its existing domain guards.
	--- @return boolean bound, string|nil error Native acknowledgement result.
	function api.bind(token, receiver)
		local lease = leases[token]
		if not lease or lease.revoked or lease.receiver ~= nil or type(receiver) ~= "function" then
			return false, "Usercontent lease is not bindable"
		end
		local entry = lease.entry
		if entry.busy or entry.pending then return false, "Usercontent callback mutation remains active" end
		lease.receiver = receiver
		if entry.bound then return true end
		entry.busy = true
		local ok, result = xpcall(function() return entry.controller:setCallback(entry.dispatch) end, debug.traceback)
		entry.busy = false
		if not ok or not rawequal(result, entry.controller) then
			entry.pending, lease.revoked, lease.receiver = lease, true, nil
			return false, tostring(result)
		end
		entry.bound = true
		if lease.revoked then return false, "Usercontent lease retired during binding" end
		return true
	end

	--- Associates an unpublished lease with its exact native window.
	--- @param token table Opaque lease token.
	--- @param view userdata|table Exact native window.
	--- @return boolean attached
	function api.attach(token, view)
		local lease = leases[token]
		if not lease or lease.revoked or (type(view) ~= "userdata" and type(view) ~= "table") then return false end
		if lease.view and not rawequal(lease.view, view) then return false end
		local prior = lease.entry.routes[view]
		if prior and prior ~= lease then return false end
		lease.view, lease.entry.routes[view] = view, lease
		return true
	end

	--- Admits messages only after the host's window publication has committed.
	--- @param token table Opaque lease token.
	--- @return boolean committed
	function api.commit(token)
		local lease = leases[token]
		if not lease or lease.revoked or not lease.view or not lease.receiver
			or not lease.entry.bound or lease.entry.pending or lease.entry.busy then return false end
		lease.committed = true
		return true
	end
	return api
end

return M
