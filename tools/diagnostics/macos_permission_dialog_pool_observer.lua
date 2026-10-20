-- tools/diagnostics/macos_permission_dialog_pool_observer.lua
-- Private read-only source-pinned observation. No native/product API is replaced.
local M = {}

local function upvalue(fn, wanted)
	local found, result, index = 0, nil, 1
	while true do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == wanted then found, result = found + 1, value end
		index = index + 1
	end
	assert(found == 1, "exact private owner is unavailable: " .. wanted)
	return result
end

--- Reads native identities and weak business references without exporting a lease.
--- @param host table Actual source-loaded PermissionDialog module.
--- @param root string Exact frozen driver root (static/ergopti_plus).
--- @return table observation Native objects and weak receiver/domain references.
local function current(host, root)
	assert(type(host) == "table" and type(host.show) == "function")
	assert(debug.getinfo(host.show, "S").source == "@" .. root .. "/macos/ui/permission_dialog/init.lua",
		"foreign PermissionDialog owner")
	local session = upvalue(host.show, "_session")
	local pool = upvalue(host.show, "ControllerPool")
	assert(type(session) == "table" and not session.opening and not session.closing
		and not session.closed and not session.releasing, "current session is not admitted")
	local view, controller, token = rawget(session, "webview"), rawget(session, "usercontent"),
		rawget(session, "controller_lease")
	assert(type(view) == "userdata" and getmetatable(view) ~= nil, "actual native view unavailable")
	assert(type(controller) == "userdata" and getmetatable(controller) ~= nil, "actual native UCC unavailable")
	assert(type(pool) == "table" and type(pool.bind) == "function", "actual pool unavailable")
	assert(debug.getinfo(pool.bind, "S").source == "@" .. root .. "/macos/ui/webview_controller_pool.lua",
		"foreign ControllerPool owner")
	local leases = upvalue(pool.bind, "leases")
	assert(type(leases) == "table", "actual pool leases unavailable")
	local lease = rawget(leases, token)
	assert(type(lease) == "table" and rawget(lease, "committed") == true
		and not rawget(lease, "revoked") and not rawget(lease, "released"), "current lease is not admitted")
	assert(rawequal(rawget(lease, "token"), token) and rawequal(rawget(lease, "view"), view),
		"current lease identity differs")
	local entry, receiver = rawget(lease, "entry"), rawget(lease, "receiver")
	assert(type(entry) == "table" and type(receiver) == "function"
		and rawequal(rawget(entry, "controller"), controller), "current native route differs")
	local routes = rawget(entry, "routes")
	assert(type(routes) == "table" and rawequal(rawget(routes, view), lease), "current view route differs")
	assert(type(rawget(session, "open_settings")) == "function", "settings callback unavailable")
	return view, controller, session, receiver, entry
end

--- Returns only native identities and weak per-window business references.
function M.snapshot(host, root)
	local view, controller, session, receiver = current(host, root)
	return { view = view, controller = controller,
		weak = setmetatable({ receiver = receiver, callback = rawget(session, "open_settings") }, { __mode = "v" }) }
end

--- Reads the real dispatch frame while the synchronous business port is running.
--- @param host table Actual source-loaded PermissionDialog module.
--- @param root string Exact frozen driver root.
--- @return table observation Raw native channel, userdata type and exact source identity.
function M.native_message(host, root)
	local view, _, _, _, entry = current(host, root)
	local dispatch = rawget(entry, "dispatch")
	local source = "@" .. root .. "/macos/ui/webview_controller_pool.lua"
	assert(type(dispatch) == "function" and debug.getinfo(dispatch, "S").source == source,
		"foreign native dispatcher")
	local frames, message, level = 0, nil, 2
	while true do
		local info = debug.getinfo(level, "fS")
		if info == nil then break end
		if rawequal(info.func, dispatch) then
			assert(info.source == source, "native dispatcher frame source differs")
			frames = frames + 1
			local found, index = 0, 1
			while true do
				local name, value = debug.getlocal(level, index)
				if name == nil then break end
				if name == "message" then found, message = found + 1, value end
				index = index + 1
			end
			assert(found == 1, "unique native dispatcher message unavailable")
		end
		level = level + 1
	end
	assert(frames == 1 and type(message) == "table", "unique live native dispatch frame unavailable")
	local name, native_view = rawget(message, "name"), rawget(message, "webView")
	assert(name == "permission_dialog_bridge" and type(native_view) == "userdata"
		and rawequal(native_view, view), "actual native message identity differs")
	return { name = name, webview_type = type(native_view), webview_exact = true,
		dispatcher_exact = true, message_parameter_observed = true }
end

return M
