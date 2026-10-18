-- tools/diagnostics/macos_webview_binding.lua
-- Real WebKit/LuaSkin observations in a private, supervisor-owned Hammerspoon.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local json = require("hs.json")
local config = assert(json.read(directory .. "/webview-config.json"))
local probe = { views = {}, controllers = {}, timers = {}, features = {}, finished = false }
_G.ERGOPTI_WEBVIEW_BINDING_PROBE = probe
local finish

local function console_check()
	local text = hs.console.getConsole()
	assert(type(text) == "string", "native console observation unavailable")
	local file = assert(io.open(config.output_dir .. "/console.txt", "wb"))
	assert(file:write(text)); assert(file:close())
	for _, pattern in ipairs({ "NOREF/REFNIL", "error invoking _gc", "NSInternalInconsistencyException" }) do
		assert(not text:find(pattern, 1, true), "native console reported " .. pattern)
	end
end

local function cleanup()
	for timer in pairs(probe.timers) do timer:stop() end
	probe.timers = {}
	for controller in pairs(probe.controllers) do
		assert(controller:setCallback(nil) == controller, "native callback detach refused")
	end
	for view in pairs(probe.views) do
		if getmetatable(view) ~= nil then
			-- Cleanup is separate from the measured visible delete() path. The
			-- public hide() takes orderOut, so delete() cannot enter a fade callback.
			assert(view:hide() == view, "cleanup hide refused")
			assert(view:isVisible() == false, "cleanup window is still visible")
			view:delete()
			assert(getmetatable(view) == nil, "cleanup retained native window userdata")
		end
	end
end
hs.shutdownCallback = cleanup

finish = function(failure)
	if probe.finished then return end
	probe.finished = true
	local cleaned, cleanup_error = xpcall(cleanup, debug.traceback)
	local console_ok, console_error = xpcall(console_check, debug.traceback)
	local receipt = {
		schema_version = 1, contract = "native.webview-binding", nonce = config.nonce,
		status = not failure and cleaned and console_ok and "ok" or "error",
		error = failure, cleanup_error = not cleaned and tostring(cleanup_error) or nil,
		console_error = not console_ok and tostring(console_error) or nil,
		pid = hs.processInfo.processID, version = hs.processInfo.version,
		source_revision = config.source_revision,
		runtime = "native Hammerspoon", features = probe.features,
		cleanup = { windows_consumed = cleaned, callbacks_detached = cleaned,
			timers_stopped = next(probe.timers) == nil, console_checked = console_ok },
		ucc_userdata_gc = "unmeasured; controllers deliberately retained",
	}
	assert(json.write(receipt, config.output_dir .. "/result.json.tmp", true, true), "result staging refused")
	assert(os.rename(config.output_dir .. "/result.json.tmp", config.output_dir .. "/result.json"),
		"result publication refused")
end

local function guarded(body)
	local ok, err = xpcall(body, debug.traceback)
	if not ok then finish(tostring(err)) end
end

local function later(body)
	local timer
	timer = hs.timer.doAfter(0.1, function()
		probe.timers[timer] = nil
		if not probe.finished then guarded(body) end
	end)
	assert(timer, "native timer construction refused")
	probe.timers[timer] = true
end

local function await(condition, body)
	later(function()
		if condition() then body() else await(condition, body) end
	end)
end

local function view_for(controller, title, x)
	local frame = { x = x, y = 80, w = 260, h = 160 }
	-- The native constructor treats an explicit third nil as a controller and
	-- rejects it. Absence must remain actual argument absence at this boundary.
	local view
	if controller ~= nil then view = hs.webview.new(frame, {}, controller)
	else view = hs.webview.new(frame, {}) end
	assert(view, "native webview construction refused")
	assert(type(view) == "userdata", "actual native webview unavailable")
	probe.views[view] = true
	assert(view:deleteOnClose(true) == view and view:deleteOnClose() == true, "native opt-in refused")
	view:windowStyle({ "titled", "closable" }):windowTitle(title)
	return view
end

local function callback_release()
	local controller = assert(hs.webview.usercontent.new("ergopti_binding"))
	probe.controllers[controller] = true
	local weak = setmetatable({}, { __mode = "v" })
	do
		local sentinel = {}
		local callback = function() return sentinel end
		weak.callback = callback
		assert(controller:setCallback(callback) == controller, "native callback bind refused")
	end
	collectgarbage("collect"); collectgarbage("collect")
	assert(weak.callback ~= nil, "native registry did not retain the callback control")
	assert(controller:setCallback(nil) == controller, "native callback removal refused")
	collectgarbage("collect"); collectgarbage("collect")
	assert(weak.callback == nil, "native callback registry still retains detached closure")
	probe.features.callback_release = {
		held_before_detach = true, collected_after_detach = true, detach_acknowledged = true,
	}
	return controller
end

local function message_identity(controller)
	local a, b = view_for(controller, "Binding A", 80), view_for(controller, "Binding B", 360)
	local ready, seen, closes = {}, {}, { a = 0, b = 0 }
	local rebound_seen = false
	for name, view in pairs({ a = a, b = b }) do
		view:navigationCallback(function(action)
			if action == "didFinishNavigation" then ready[name] = true end
			return true
		end)
		view:windowCallback(function(action, exact)
			if action == "closing" then
				assert(rawequal(exact, view), "closing callback borrowed another native view")
				closes[name] = closes[name] + 1
			end
		end)
		view:html("<!doctype html><html><body>Native binding observation</body></html>")
		view:show()
	end
	assert(controller:setCallback(function(message)
		guarded(function()
			assert(message.name == "ergopti_binding", "foreign message port")
			assert(rawequal(message.webView, a), "initial native message did not originate in A")
			local body = assert(message.body)
			assert(body.nonce == config.nonce and body.kind == "initial-a", "foreign initial native message")
			seen["initial-a"] = { source_exact = true, admitted = true }
		end)
	end) == controller, "shared controller binding refused")
	local function post(view, kind)
		view:evaluateJavaScript("window.webkit.messageHandlers.ergopti_binding.postMessage(" ..
			assert(json.encode({ nonce = config.nonce, kind = kind })) .. ")", function(_, error)
			guarded(function() assert(error == nil, "native JavaScript message failed") end)
		end)
	end
	await(function() return ready.a and ready.b end, function()
		post(a, "initial-a")
		await(function() return seen["initial-a"] end, function()
			assert(seen["initial-a"].admitted, "healthy native A message refused")
			assert(controller:setCallback(nil) == controller, "initial callback detach refused")
			-- Reuse the real controller with a distinct B closure. Route on the
			-- native source before reading Lua body fields, even for a late A post.
			assert(controller:setCallback(function(message)
				guarded(function()
					rebound_seen = true
					assert(message.name == "ergopti_binding", "foreign rebound message port")
					if not rawequal(message.webView, b) then
						assert(rawequal(message.webView, a), "rebound message source was neither A nor B")
						seen["stale-a"] = { source_exact = true, admitted = false }
						return
					end
					local body = assert(message.body)
					assert(body.nonce == config.nonce and body.kind == "current-b", "foreign B message")
					seen["current-b"] = { source_exact = true, admitted = true }
				end)
			end) == controller, "successor callback bind refused")
			post(a, "stale-a")
			post(b, "current-b")
			await(function() return seen["stale-a"] and seen["current-b"] end, function()
				assert(not seen["stale-a"].admitted, "previous view message adopted successor authority")
				assert(seen["current-b"].admitted, "healthy native B message refused")
				assert(rebound_seen, "successor native callback never ran")
				cleanup()
				assert(closes.a == 1 and closes.b == 1, "native A/B close callbacks were not exact-once")
				probe.features.message_identity = { initial_a_exact = true, current_b_exact = true,
					rebound_b_callback = rebound_seen,
					stale_a_rejected = true, current_b_accepted = true, a_closes = closes.a, b_closes = closes.b }
				later(function() console_check(); finish() end)
			end)
		end)
	end)
end

guarded(function()
	assert(hs.processInfo.version == config.expected_version, "unexpected native runtime")
	assert(hs.screen.mainScreen(), "no native GUI screen")
	local timeout = hs.timer.doAfter(45, function() finish("native binding deadline exceeded") end)
	probe.timers[assert(timeout)] = true
	local view = view_for(nil, "Visible delete wrapper", 80)
	local closes = 0
	view:windowCallback(function(action, exact)
		guarded(function()
			if action == "closing" then
				assert(rawequal(exact, view), "visible delete closed a foreign owner")
				closes = closes + 1
			end
		end)
	end)
	view:show()
	later(function()
		assert(view:isVisible() == true, "wrapper control was not visibly presented")
		-- Deliberately use the public no-argument wrapper, including its native
		-- fadeOut(0) completion. Do not substitute hide(), _delete or manual GC.
		view:delete()
		await(function() return getmetatable(view) == nil end, function()
			assert(closes == 1, "visible delete callback was not exact-once")
			console_check()
			probe.features.visible_wrapper_delete = {
				visible_before = true, delete_on_close = true, exact_close_count = closes,
				userdata_consumed = true, runloop_continued = true,
			}
			message_identity(callback_release())
		end)
	end)
end)
