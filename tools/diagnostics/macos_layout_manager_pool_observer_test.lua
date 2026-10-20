-- Pure observer controls; file userdata below are NOT native WebViews or Cocoa.
-- These controls qualify only read-only traversal, denial and weak retention.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local Observer = assert(dofile(directory .. "/macos_layout_manager_pool_observer.lua"))
local root = "/pure-unit-only/ergopti_plus"
local production = assert(arg[2], "pass the actual static/ergopti_plus root as argument 2")

local function fixture()
	local view, controller = assert(io.tmpfile()), assert(io.tmpfile())
	local token, leases = {}, {}
	local receiver = function() error("observer must never invoke receiver") end
	local domain = { on_message = assert(load([[local ready=false; return function() return ready end]],
		"@" .. root .. "/macos/ui/layout_manager/init.lua"))() }
	local entry = { controller = controller, routes = {} }
	local lease = { token = token, view = view, receiver = receiver, entry = entry, committed = true }
	leases[token], entry.routes[view] = lease, lease
	local bind = assert(load([[local leases=...; return function() return leases end]],
		"@" .. root .. "/macos/ui/webview_controller_pool.lua"))(leases)
	local pool = { bind = bind }
	local open = assert(load([[
		local _webview,_usercontent,_controller,_controller_lease,ControllerPool=...
		return function(clear)
			if clear then _webview,_usercontent,_controller,_controller_lease=nil,nil,nil,nil end
			return _webview,_usercontent,_controller,_controller_lease,ControllerPool
		end]], "@" .. root .. "/macos/ui/layout_manager/init.lua"))(view, controller, domain, token, pool)
	return { open = open }, lease, entry, leases, view, controller, pool
end

local cases = {
	{ "read-only snapshot exposes no mutable authority", function(host, lease, entry, leases, view, controller)
		local seen = Observer.snapshot(host, root)
		assert(rawequal(seen.view, view) and rawequal(seen.controller, controller) and seen.ready == false)
		assert(rawequal(seen.weak.receiver, lease.receiver) and rawequal(seen.weak.domain, select(3, host.open())))
		local count = 0
		for key in pairs(seen) do assert(key == "view" or key == "controller" or key == "weak" or key == "ready"); count=count+1 end
		assert(count == 4 and lease.committed and not lease.revoked and entry.routes[view] == lease)
		assert(leases[lease.token] == lease and type(lease.receiver) == "function")
	end },
	{ "weak observers do not pin retired business", function(host, lease, entry, leases)
		local seen = Observer.snapshot(host, root)
		host.open(true); entry.routes = {}; leases[lease.token] = nil; lease.receiver = nil
		collectgarbage("collect"); collectgarbage("collect")
		assert(seen.weak.receiver == nil and seen.weak.domain == nil)
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
	local pool = Pool.new(function(name) assert(name == "layout_manager_bridge"); return controller end,
		{ error = function(_, _, detail) failures[#failures+1] = detail end })
	local token, uc = pool.reserve("layout_manager"); assert(rawequal(uc, controller))
	local domain = { on_message = assert(load([[local ready=true;return function()return ready end]],
		"@" .. production .. "/macos/ui/layout_manager/init.lua"))() }
	local open = assert(load([[
		local _webview,_usercontent,_controller,_controller_lease,ControllerPool=...
		return function() return _webview,_usercontent,_controller,_controller_lease,ControllerPool end]],
		"@" .. production .. "/macos/ui/layout_manager/init.lua"))(view, controller, domain, token, pool)
	local host, depth = { open = open }, 0
	assert(pool.bind(token, function(message)
		if kind == "nested" and depth == 0 then depth = 1; callback(message); return end
		observations[#observations+1] = Observer.native_message(host, production)
	end))
	assert(pool.attach(token, view) and pool.commit(token))
	local message = { name = "layout_manager_bridge", webView = view, body = { action = "refresh" } }
	if kind == "foreign-name" then message.name = "foreign" end
	if kind == "foreign-view" then message.webView = controller end
	if kind == "outside" then
		assert(not pcall(Observer.native_message, host, production))
	else callback(message) end
	if kind == "healthy" then
		assert(#observations == 1 and #failures == 0)
		local observed = observations[1]
		assert(observed.name == "layout_manager_bridge" and observed.webview_type == "userdata"
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
	local ok, failure = xpcall(function() case[2](host, lease, entry, leases, view, controller, pool) end, debug.traceback)
	assert(view:close()); assert(controller:close()); assert(ok, failure)
	print("PASS_PURE_OBSERVER", case[1])
end
print("PURE_OBSERVER_ONLY", #cases)
