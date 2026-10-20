-- tools/diagnostics/macos_permission_dialog_pool.lua
-- Actual PermissionDialog/ControllerPool. Only the settings business callback
-- is controlled; no native function, receiver or product state is replaced.
local M = {}

function M.run(config, done)
	assert(type(config) == "table" and type(done) == "function")
	local root = assert(config.production_root)
	assert(config.expected_version == hs.processInfo.version and type(config.nonce) == "string")
	package.path = root .. "/macos/?.lua;" .. root .. "/macos/?/init.lua;"
		.. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path
	local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
	local Observer = assert(dofile(directory .. "/macos_permission_dialog_pool_observer.lua"))
	local Logger = require("infra.logger")
	local policy = assert(io.open(root .. "/_shared/modules/diagnostics/redaction.json", "rb"))
	local raw_policy = assert(policy:read("*a")); assert(policy:close())
	Logger.initialize_privacy(raw_policy)
	assert(package.loaded["ui.permission_dialog"] == nil, "PermissionDialog already loaded")
	assert(package.loaded["ui.webview_controller_pool"] == nil, "ControllerPool already loaded")
	assert(rawequal(require("hs.webview"), hs.webview), "native WebView identity differs")
	assert(hs.screen.mainScreen(), "native GUI unavailable")
	local native = { view_new = hs.webview.new, controller_new = hs.webview.usercontent.new,
		after = hs.timer.doAfter }
	assert(debug.getinfo(native.view_new, "S").what == "C", "WebView constructor is not native")
	assert(debug.getinfo(native.controller_new, "S").what == "C", "UCC constructor is not native")
	local view_methods = assert(hs.getObjectMetatable("hs.webview"))
	local controller_methods = assert(hs.getObjectMetatable("hs.webview.usercontent"))
	local methods = { "windowCallback", "delete", "evaluateJavaScript", "hswindow", "deleteOnClose", "allowNewWindows" }
	for _, name in ipairs(methods) do native[name] = assert(view_methods[name]) end
	native.setCallback = assert(controller_methods.setCallback)
	local Host = require("ui.permission_dialog")
	local UI, Pool = require("ui.ui_builder"), require("ui.webview_controller_pool")
	local Scheduler, Result = require("adapters.timer_scheduler"), require("adapters.webview_result")
	require("infra.i18n").init()
	for fn, suffix in pairs({ [Host.show] = "/macos/ui/permission_dialog/init.lua",
		[Pool.new] = "/macos/ui/webview_controller_pool.lua", [UI.show_webview] = "/macos/ui/ui_builder.lua",
		[Scheduler.activeCount] = "/macos/adapters/timer_scheduler.lua" }) do
		assert(debug.getinfo(fn, "S").source == "@" .. root .. suffix, "foreign production owner")
	end
	local state = { entries = {}, timers = {}, evaluations = {}, errors = {}, finished = false, phase = "starting" }
	local baseline, started = Scheduler.activeCount(), hs.timer.absoluteTime()
	local receipt, finish = {}, nil
	local function guarded(body)
		if state.finished then return end
		local ok, failure = xpcall(body, debug.traceback)
		if not ok then state.errors[#state.errors + 1] = tostring(failure); finish() end
	end
	local function later(body)
		local timer
		timer = assert(hs.timer.doAfter(0.05, function()
			state.timers[timer] = nil
			guarded(body)
		end))
		state.timers[timer] = true
	end
	local function await(condition, body)
		later(function()
			assert((hs.timer.absoluteTime() - started) / 1e9 < 35, "PermissionDialog native deadline exceeded")
			if condition() then body() else await(condition, body) end
		end)
	end
	finish = function()
		if state.finished then return end
		state.finished = true
		for timer in pairs(state.timers) do
			local ok, ack = pcall(function() return timer:stop() end)
			if not ok or not rawequal(ack, timer) then state.errors[#state.errors + 1] = "probe timer stop refused" end
		end
		state.timers = {}
		receipt.schema_version, receipt.contract = 1, "native.permission-dialog-controller-pool"
		receipt.observation = "private source-pinned observer; read-only Lua upvalue inspection"
		receipt.native_identity = "private read-only dispatch stack; raw native name and exact webView observed"
		receipt.weak_scope = "per-window lease receiver, settings callback and sentinel; pooled dispatcher retained"
		receipt.nonce, receipt.source_revision = config.nonce, config.source_revision
		receipt.source_manifest_digest = config.source_manifest_digest
		receipt.pid, receipt.version, receipt.arch = hs.processInfo.processID, hs.processInfo.version, hs.processInfo.arch
		receipt.status, receipt.errors = #state.errors == 0 and "ok" or "error", state.errors
		receipt.native_input = "not attempted; no physical input, synthetic key or AppleEvent"
		receipt.business_scope = "open_settings callback recorded; no System Settings opened or permission granted"
		receipt.ucc_userdata_gc = "unmeasured; actual controller deliberately retained"
		receipt.native_apis_unmodified = rawequal(hs.webview.new, native.view_new)
			and rawequal(hs.webview.usercontent.new, native.controller_new)
			and rawequal(controller_methods.setCallback, native.setCallback) and rawequal(hs.timer.doAfter, native.after)
		for _, name in ipairs(methods) do
			if not rawequal(view_methods[name], native[name]) then receipt.native_apis_unmodified = false end
		end
		receipt.settings_callbacks_collected = #state.entries == 2
		for _, entry in ipairs(state.entries) do
			if not entry.weak or entry.weak.receiver or entry.weak.callback or entry.weak.sentinel then
				receipt.settings_callbacks_collected = false
			end
		end
		receipt.product_timer_baseline, receipt.product_timer_final = baseline, Scheduler.activeCount()
		if #state.errors > 0 then receipt.failure_phase = state.phase end
		done(receipt, state.evaluations)
	end
	state.timers[assert(hs.timer.doAfter(35, function()
		guarded(function() error("PermissionDialog native deadline exceeded") end)
	end))] = true
	hs.shutdownCallback = function() Host.close() end
	local function open(phase)
		state.phase = "open_" .. phase
		local entry = { phase = phase, settings = 0, closed = 0 }
		state.entries[#state.entries + 1] = entry
		local weak = setmetatable({}, { __mode = "v" })
		do
			local sentinel = { phase = phase, nonce = config.nonce }
			local callback = function()
				guarded(function()
					assert(sentinel.phase == phase and sentinel.nonce == config.nonce, "foreign settings callback")
					entry.settings = entry.settings + 1
					assert(entry.settings == 1 and entry.native_message == nil, "duplicate settings callback")
					entry.native_message = Observer.native_message(Host, root)
				end)
				return true -- Record the actual page action; never launch System Settings.
			end
			weak.callback, weak.sentinel = callback, sentinel
			assert(Host.show({ kind = "login_items", open_settings = callback,
				on_closed = function() entry.closed = entry.closed + 1 end }) == true, "actual PermissionDialog show refused")
		end
		local observed = Observer.snapshot(Host, root)
		entry.view, entry.controller, entry.weak = observed.view, observed.controller, observed.weak
		assert(rawequal(entry.weak.callback, weak.callback), "foreign actual settings callback")
		entry.weak.sentinel = weak.sentinel
		local window = assert(entry.view:hswindow())
		entry.host_pid, entry.window_id = window:application():pid(), window:id()
		assert(entry.host_pid == hs.processInfo.processID and math.type(entry.window_id) == "integer"
			and entry.window_id > 0, "native window identity unavailable")
		assert(entry.view:deleteOnClose() == false and entry.view:allowNewWindows() == false, "native policy differs")
		collectgarbage("collect"); collectgarbage("collect")
		assert(entry.weak.receiver and entry.weak.callback and entry.weak.sentinel, "healthy retention absent")
		return entry, window
	end
	local function settings(entry, after)
		state.phase = "settings_" .. entry.phase
		local function ready()
			entry.view:evaluateJavaScript("Boolean(document.getElementById('open')"
				.. " && !document.getElementById('open').disabled"
				.. " && typeof document.getElementById('open').onclick==='function')", function(value, failure)
					guarded(function()
						state.evaluations[#state.evaluations + 1] = { phase = entry.phase, kind = "ready",
							value_type = type(failure), metatable_type = type(getmetatable(failure)),
							result_type = type(value), result = value, value = failure }
						assert(not Result.is_error(failure) and type(value) == "boolean", "native readiness refused")
						if not value then later(ready); return end
						entry.view:evaluateJavaScript("const button=document.getElementById('open');"
							.. " if(!button || button.disabled || typeof button.onclick!=='function') throw new Error('Settings unavailable');"
							.. " button.click(); true", function(result, error_value)
								guarded(function()
									state.evaluations[#state.evaluations + 1] = { phase = entry.phase, kind = "settings",
										value_type = type(error_value), metatable_type = type(getmetatable(error_value)),
										result_type = type(result), result = result, value = error_value }
									assert(not Result.is_error(error_value) and result == true, "native settings evaluation refused")
									entry.javascript_completed = true
								end)
							end)
						await(function() return entry.settings == 1 and entry.javascript_completed end, after)
					end)
				end)
		end
		await(function() return entry.view:isVisible() == true end, ready)
	end

	local function close(entry, window, after)
		state.phase = "close_" .. entry.phase
		assert(window:close() == true, "actual AX close refused; no public delete fallback")
		entry.ax_close_ack = true
		await(function()
			collectgarbage("collect"); collectgarbage("collect")
			return getmetatable(entry.view) == nil and not entry.weak.receiver and not entry.weak.callback
				and not entry.weak.sentinel and Scheduler.activeCount() == baseline and not Host.is_open()
		end, function()
			assert(entry.settings == 1 and entry.closed == 1, "retired business or close callback differs")
			receipt[entry.phase] = { window_id = entry.window_id, host_pid = entry.host_pid,
				visible_before = true, native_policy_observed = true, retained_before = true,
				business_settings = entry.settings, javascript_completed = entry.javascript_completed == true,
				ax_close_ack = entry.ax_close_ack, userdata_consumed = true, receiver_collected = true,
				callback_collected = true, sentinel_collected = true, owner_closed_once = true,
				product_timer_retired = true, native_message = assert(entry.native_message) }
			after()
		end)
	end
	guarded(function()
		local a, window_a = open("a")
		settings(a, function()
			close(a, window_a, function()
				receipt.a_retired_before_b_open = true
				local b, window_b = open("b")
				assert(not rawequal(a.view, b.view), "B reused consumed native view")
				assert(rawequal(a.controller, b.controller), "PermissionDialog did not reuse its exact UCC")
				receipt.same_ucc_exact, receipt.distinct_views = true, true
				settings(b, function()
					assert(a.settings == 1 and not a.weak.receiver and not a.weak.callback
						and not a.weak.sentinel and getmetatable(a.view) == nil, "B revived retired A")
					close(b, window_b, function()
						receipt.a_settings_count_unchanged = true
						assert(Host.close() == true, "settled permission close was not idempotent")
						state.phase = "complete"
						finish()
					end)
				end)
			end)
		end)
	end)
	return state
end

return M
