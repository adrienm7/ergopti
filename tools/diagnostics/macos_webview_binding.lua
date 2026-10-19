-- tools/diagnostics/macos_webview_binding.lua
-- Real WebKit/LuaSkin observations in a private, supervisor-owned Hammerspoon.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local json = require("hs.json")
local config = assert(json.read(directory .. "/webview-config.json"))
local probe = { views = {}, controllers = {}, timers = {}, features = {}, evaluations = {}, finished = false }
_G.ERGOPTI_WEBVIEW_BINDING_PROBE = probe
local finish
local WebViewResult
local UI

local function console_check()
	local text = hs.console.getConsole()
	assert(type(text) == "string", "native console observation unavailable")
	local file = assert(io.open(config.output_dir .. "/console.txt", "wb"))
	assert(file:write(text)); assert(file:close())
	for _, pattern in ipairs({ "NOREF/REFNIL", "error invoking _gc", "NSInternalInconsistencyException" }) do
		assert(not text:find(pattern, 1, true), "native console reported " .. pattern)
	end
	assert(not text:find("%f[%a]ERROR%f[%A]"), "production factory reported an error")
end

local function cleanup()
	for timer in pairs(probe.timers) do timer:stop() end
	probe.timers = {}
	for controller in pairs(probe.controllers) do
		assert(controller:setCallback(nil) == controller, "native callback detach refused")
	end
	for view in pairs(probe.views) do
		if getmetatable(view) ~= nil then
			assert(view:deleteOnClose() == false, "product cleanup rearmed recursive native GC")
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
		schema_version = 3, contract = "native.webview-binding", nonce = config.nonce,
		status = not failure and cleaned and console_ok and "ok" or "error",
		error = failure, cleanup_error = not cleaned and tostring(cleanup_error) or nil,
		console_error = not console_ok and tostring(console_error) or nil,
		pid = hs.processInfo.processID, version = hs.processInfo.version,
		source_revision = config.source_revision,
		runtime = "native Hammerspoon", features = probe.features,
		window_identity = probe.window_identity,
		scope = "production ui.ui_builder.show_webview; native WebView/UCC bindings",
		cleanup = { windows_consumed = cleaned, callbacks_detached = cleaned,
			timers_stopped = next(probe.timers) == nil, console_checked = console_ok },
		ucc_userdata_gc = "unmeasured; controllers deliberately retained",
	}
	assert(json.write(probe.evaluations, config.output_dir .. "/evaluations.json", true, true),
		"JavaScript completion evidence publication refused")
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

local function view_for(controller, title, x, closed, navigated)
	local frame = { x = x, y = 80, w = 260, h = 160 }
	local view
	local created = UI.show_webview({ frame = frame, title = title,
		style_masks = { "titled", "closable" }, focus = false, inject_i18n = false,
		delete_on_close = true, usercontent = controller,
		html_string = "<!doctype html><html><body>Native product binding observation</body></html>",
		on_webview_created = function(candidate)
			assert(type(candidate) == "userdata", "actual product WebView unavailable")
			assert(candidate:deleteOnClose() == false, "factory left recursive native GC enabled before publication")
			view = candidate
			probe.views[view] = true
			return true
		end,
		on_close = function() guarded(function() if closed then closed() end end) end,
		on_navigation = navigated,
	})
	assert(created and rawequal(created, view), "product factory did not publish its exact candidate")
	assert(view:deleteOnClose() == false, "product factory rearmed recursive native GC")
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
	local ready, seen, evaluated, closes = {}, {}, {}, { a = 0, b = 0 }
	local views = {}
	local rebound_seen, post_a_gc_requested = false, false
	for index, name in ipairs({ "a", "b" }) do
		views[name] = view_for(controller, "Binding " .. name, 80 + (index - 1) * 280, function()
			closes[name] = closes[name] + 1
		end, function(action)
			if action == "didFinishNavigation" then ready[name] = true end
			return true
		end)
	end
	local a, b = views.a, views.b
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
			assert(json.encode({ nonce = config.nonce, kind = kind })) .. "); true", function(value, error)
			guarded(function()
				local details = { kind = kind, value_type = type(error), metatable_type = type(getmetatable(error)),
					result_type = type(value), result = value }
				details.value = error
				probe.evaluations[#probe.evaluations + 1] = details
				assert(not WebViewResult.is_error(error), "native JavaScript message failed: " ..
					assert(json.encode(details), "native error serialization refused"))
				assert(value == true, "native JavaScript completion did not return primitive true")
				evaluated[kind] = true
			end)
		end)
	end
	await(function() return ready.a and ready.b end, function()
		post(a, "initial-a")
		await(function() return seen["initial-a"] and evaluated["initial-a"] end, function()
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
					assert(body.nonce == config.nonce and (body.kind == "current-b"
						or body.kind == "current-b-after-a-gc"), "foreign B message")
					if body.kind == "current-b-after-a-gc" then
						assert(post_a_gc_requested and getmetatable(a) == nil and closes.a == 1 and closes.b == 0,
							"B post arrived before exact A consumption")
					end
					seen[body.kind] = { source_exact = true, admitted = true }
				end)
			end) == controller, "successor callback bind refused")
			post(a, "stale-a")
			post(b, "current-b")
			await(function() return seen["stale-a"] and seen["current-b"]
				and evaluated["stale-a"] and evaluated["current-b"] end, function()
				assert(not seen["stale-a"].admitted, "previous view message adopted successor authority")
				assert(seen["current-b"].admitted, "healthy native B message refused")
				assert(rebound_seen, "successor native callback never ran")
				-- Measure each business owner independently: a callback captured by
				-- the factory is not a native source-identity argument.
				assert(a:hide() == a, "A hide refused")
				a:delete()
				assert(getmetatable(a) == nil and closes.a == 1 and closes.b == 0 and b:isVisible(),
					"A close callback affected the B owner")
				-- Do not rebind/detach: exercise the exact B callback and UCC
				-- which survived A's native userdata cleanup.
				post_a_gc_requested = true
				post(b, "current-b-after-a-gc")
				await(function() return seen["current-b-after-a-gc"] and evaluated["current-b-after-a-gc"] end, function()
					assert(getmetatable(a) == nil and closes.a == 1 and closes.b == 0 and b:isVisible(),
						"post-GC B delivery changed exact window owners")
					assert(b:hide() == b, "B hide refused")
					b:delete()
					assert(getmetatable(b) == nil and closes.a == 1 and closes.b == 1,
						"B close callback affected the A owner")
					cleanup()
					probe.features.message_identity = { initial_a_exact = true, current_b_exact = true,
						rebound_b_callback = rebound_seen,
						b_after_a_gc_source_exact = seen["current-b-after-a-gc"].source_exact,
						b_after_a_gc_accepted = seen["current-b-after-a-gc"].admitted,
						b_after_a_gc_evaluated = evaluated["current-b-after-a-gc"],
						stale_a_rejected = true, current_b_accepted = true, a_close_preserved_b = true, a_closes = closes.a, b_closes = closes.b }
					later(function() console_check(); finish() end)
				end)
			end)
		end)
	end)
end

guarded(function()
	local root = assert(config.production_root)
	package.path = root .. "/macos/?.lua;" .. root .. "/macos/?/init.lua;"
		.. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path
	local Logger = require("infra.logger")
	local policy = assert(io.open(root .. "/_shared/modules/diagnostics/redaction.json", "rb"))
	local raw_policy = assert(policy:read("*a")); assert(policy:close())
	Logger.initialize_privacy(raw_policy)
	WebViewResult = require("adapters.webview_result")
	UI = require("ui.ui_builder")
	local Owner = require("ui.webview_close_owner")
	assert(debug.getinfo(UI.show_webview, "S").source == "@" .. root .. "/macos/ui/ui_builder.lua",
		"factory did not load from frozen production source")
	assert(debug.getinfo(Owner.new, "S").source == "@" .. root .. "/macos/ui/webview_close_owner.lua",
		"close owner did not load from frozen production source")
	assert(hs.processInfo.version == config.expected_version, "unexpected native runtime")
	assert(hs.screen.mainScreen(), "no native GUI screen")
	local timeout = hs.timer.doAfter(45, function() finish("native binding deadline exceeded") end)
	probe.timers[assert(timeout)] = true
	local closes, explicit, user = { explicit = 0, user = 0 }
	explicit = view_for(nil, "Product explicit close", 80, function()
		closes.explicit = closes.explicit + 1
	end)
	user = view_for(nil, "Product native close button", 360, function()
		closes.user = closes.user + 1
	end)
	later(function()
		assert(explicit:isVisible() and user:isVisible(), "product windows were not visibly presented")
		local explicit_window, user_window = assert(explicit:hswindow()), assert(user:hswindow())
		local explicit_id, user_id = explicit_window:id(), user_window:id()
		assert(math.type(explicit_id) == "integer" and explicit_id > 0, "explicit native window identity missing")
		assert(math.type(user_id) == "integer" and user_id > 0 and user_id ~= explicit_id,
			"native user window identity missing or aliased")
		assert(explicit_window:application():pid() == hs.processInfo.processID
			and user_window:application():pid() == hs.processInfo.processID, "foreign native window host")
		probe.window_identity = { explicit = explicit_id, user = user_id, host_pid = hs.processInfo.processID }
		explicit:delete()
		await(function() return getmetatable(explicit) == nil end, function()
			assert(closes.explicit == 1 and closes.user == 0 and user:isVisible(), "explicit close damaged its successor")
			probe.features.explicit_product_close = { visible_before = true, native_auto_delete_disabled = true,
				exact_close_count = closes.explicit, userdata_consumed = true, runloop_continued = true,
				sibling_survived = true }
			assert(user_window:close() == true, "native close-button request refused; no delete fallback")
			await(function() return getmetatable(user) == nil end, function()
				assert(closes.user == 1, "native user close callback was not exact-once")
				probe.features.user_product_close = { visible_before = true, native_auto_delete_disabled = true,
					native_close_button_requested = true, exact_close_count = closes.user, userdata_consumed = true }
				message_identity(callback_release())
			end)
		end)
	end)
end)
