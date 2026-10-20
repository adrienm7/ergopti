-- Pure observer controls; file userdata below are NOT native WebViews or Cocoa.
-- These controls qualify only read-only traversal, denial and weak retention.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local Observer = assert(dofile(directory .. "/macos_permission_dialog_pool_observer.lua"))
local root = "/pure-unit-only/ergopti_plus"
local production = assert(arg[2], "pass the actual static/ergopti_plus root as argument 2")

local function fixture()
	local view, controller = assert(io.tmpfile()), assert(io.tmpfile())
	local token, leases = {}, {}
	local receiver = function() error("observer must never invoke receiver") end
	local domain = function() return true end
	local entry = { controller = controller, routes = {} }
	local lease = { token = token, view = view, receiver = receiver, entry = entry, committed = true }
	leases[token], entry.routes[view] = lease, lease
	local bind = assert(load([[local leases=...; return function() return leases end]],
		"@" .. root .. "/macos/ui/webview_controller_pool.lua"))(leases)
	local pool = { bind = bind }
	local session = { webview = view, usercontent = controller, controller_lease = token, open_settings = domain }
	local open = assert(load([[
		local _session,ControllerPool=...
		return function(clear)
			if clear then _session=nil end
			return _session,ControllerPool
		end]], "@" .. root .. "/macos/ui/permission_dialog/init.lua"))(session, pool)
	return { show = open }, lease, entry, leases, view, controller, pool
end

local cases = {
	{ "read-only snapshot exposes no mutable authority", function(host, lease, entry, leases, view, controller)
		local seen = Observer.snapshot(host, root)
		assert(rawequal(seen.view, view) and rawequal(seen.controller, controller))
		assert(rawequal(seen.weak.receiver, lease.receiver) and rawequal(seen.weak.callback, host.show().open_settings))
		local count = 0
		for key in pairs(seen) do assert(key == "view" or key == "controller" or key == "weak"); count=count+1 end
		assert(count == 3 and lease.committed and not lease.revoked and entry.routes[view] == lease)
		assert(leases[lease.token] == lease and type(lease.receiver) == "function")
	end },
	{ "weak observers do not pin retired business", function(host, lease, entry, leases)
		local seen = Observer.snapshot(host, root)
		host.show(true); entry.routes = {}; leases[lease.token] = nil; lease.receiver = nil
		collectgarbage("collect"); collectgarbage("collect")
		assert(seen.weak.receiver == nil and seen.weak.callback == nil)
	end },
	{ "foreign host source refuses", function(host)
		local ok = pcall(Observer.snapshot, host, root .. "/foreign"); assert(not ok)
	end },
	{ "revoked lease refuses", function(host, lease)
		lease.revoked = true; assert(not pcall(Observer.snapshot, host, root))
	end },
	{ "uncommitted lease refuses", function(host, lease)
		lease.committed = false; assert(not pcall(Observer.snapshot, host, root))
	end },
	{ "foreign view route refuses", function(host, lease, entry, _, view)
		entry.routes[view] = {}; assert(not pcall(Observer.snapshot, host, root))
	end },
	{ "foreign controller refuses", function(host, lease, entry)
		entry.controller = {}; assert(not pcall(Observer.snapshot, host, root))
	end },
	{ "foreign pool source refuses", function(host, lease, entry, leases, view, controller, pool)
		pool.bind = function() return leases end; assert(not pcall(Observer.snapshot, host, root))
	end },
}

-- These cases execute the actual Pool dispatcher and its xpcall path. File
-- userdata and setCallback are explicit controlled ports, never native evidence.
local function dispatch_control(kind)
	local source_path = production .. "/macos/ui/webview_controller_pool.lua"
	local file = assert(io.open(source_path, "rb")); local code = assert(file:read("*a")); assert(file:close())
	if kind == "renamed" then code = code:gsub("%f[%w]message%f[%W]", "packet") end
	local Pool = assert(load(code, "@" .. source_path))()
	local view, controller = assert(io.tmpfile()), assert(io.tmpfile())
	local original = getmetatable(controller)
	local methods = setmetatable({}, { __index = original.__index })
	local callback, observations, failures = nil, {}, {}
	methods.setCallback = function(self, fn) callback = fn; return self end
	local metadata = {}; for key, value in pairs(original) do metadata[key] = value end
	metadata.__index = methods; debug.setmetatable(controller, metadata)
	local pool = Pool.new(function(name) assert(name == "permission_dialog_bridge"); return controller end,
		{ error = function(_, _, detail) failures[#failures+1] = detail end })
	local token, uc = pool.reserve("permission_dialog"); assert(rawequal(uc, controller))
	local session = { webview = view, usercontent = controller, controller_lease = token,
		open_settings = function() return true end }
	local open = assert(load([[
		local _session,ControllerPool=...
		return function() return _session,ControllerPool end]],
		"@" .. production .. "/macos/ui/permission_dialog/init.lua"))(session, pool)
	local host, depth = { show = open }, 0
	assert(pool.bind(token, function(message)
		if kind == "nested" and depth == 0 then depth = 1; callback(message); return end
		observations[#observations+1] = Observer.native_message(host, production)
	end))
	assert(pool.attach(token, view) and pool.commit(token))
	local message = { name = "permission_dialog_bridge", webView = view, body = { action = "refresh" } }
	if kind == "foreign-name" then message.name = "foreign" end
	if kind == "foreign-view" then message.webView = controller end
	if kind == "outside" then
		assert(not pcall(Observer.native_message, host, production))
	else callback(message) end
	if kind == "healthy" then
		assert(#observations == 1 and #failures == 0)
		local observed = observations[1]
		assert(observed.name == "permission_dialog_bridge" and observed.webview_type == "userdata"
			and observed.webview_exact and observed.dispatcher_exact and observed.message_parameter_observed)
	elseif kind == "renamed" then
		assert(#observations == 0 and #failures == 1 and tostring(failures[1]):find("unique native dispatcher message", 1, true))
	elseif kind == "nested" then
		assert(#observations == 0 and #failures == 1 and tostring(failures[1]):find("unique live native dispatch frame", 1, true))
	else assert(#observations == 0 and #failures == 0) end
	assert(pool.release(token)); assert(callback == nil)
	assert(view:close()); debug.setmetatable(controller, original); assert(controller:close())
end
for _, kind in ipairs({ "healthy", "renamed", "nested", "outside", "foreign-name", "foreign-view" }) do
	cases[#cases+1] = { "real Pool stack observation " .. kind, function() dispatch_control(kind) end }
end
if arg[1] == "reverse" then
	local reversed = {}; for i = #cases, 1, -1 do reversed[#reversed+1] = cases[i] end; cases = reversed
end
if arg[1] and arg[1]:match("^case:") then cases = { assert(cases[tonumber(arg[1]:sub(6))]) } end
for _, case in ipairs(cases) do
	local host, lease, entry, leases, view, controller, pool = fixture()
	local globals, cache = {}, {}
	for key, value in pairs(_G) do globals[key] = value end
	for key, value in pairs(package.loaded) do cache[key] = value end
	local ok, failure = xpcall(function() case[2](host, lease, entry, leases, view, controller, pool) end, debug.traceback)
	assert(view:close()); assert(controller:close()); assert(ok, failure)
	for key, value in pairs(_G) do assert(globals[key] == value, "global changed: " .. key) end
	for key, value in pairs(globals) do assert(_G[key] == value, "global lost: " .. key) end
	for key, value in pairs(package.loaded) do assert(cache[key] == value, "cache changed: " .. key) end
	for key, value in pairs(cache) do assert(package.loaded[key] == value, "cache lost: " .. key) end
	print("PASS_PURE_OBSERVER", case[1], "GLOBALS_DELTA=0 CACHE_DELTA=0")
end
print("PURE_OBSERVER_ONLY", #cases)
