-- tools/diagnostics/macos_action_picker_pool.lua
-- Actual ActionPicker/ControllerPool qualification, private source-pinned observer.
-- Native methods are never replaced. Only discovery business ports are controlled.
local M = {}

function M.run(config, done)
	assert(type(config) == "table" and type(done) == "function")
	local root = assert(config.production_root)
	assert(config.expected_version == hs.processInfo.version and type(config.nonce) == "string")
	package.path = root .. "/macos/?.lua;" .. root .. "/macos/?/init.lua;"
		.. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path
	local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
	local Observer = assert(dofile(directory .. "/macos_action_picker_pool_observer.lua"))
	local Logger = require("infra.logger")
	local policy = assert(io.open(root .. "/_shared/modules/diagnostics/redaction.json", "rb"))
	local raw_policy = assert(policy:read("*a")); assert(policy:close())
	Logger.initialize_privacy(raw_policy)
	assert(package.loaded["ui.action_picker"] == nil, "ActionPicker was already loaded")
	assert(package.loaded["ui.webview_controller_pool"] == nil, "ControllerPool was already loaded")
	assert(rawequal(require("hs.webview"), hs.webview), "native WebView module identity differs")
	assert(hs.screen.mainScreen(), "native GUI unavailable")
	local native = { view_new = hs.webview.new, controller_new = hs.webview.usercontent.new }
	assert(debug.getinfo(native.view_new, "S").what == "C", "WebView constructor is not native")
	assert(debug.getinfo(native.controller_new, "S").what == "C", "UCC constructor is not native")
	local view_methods = assert(hs.getObjectMetatable("hs.webview"))
	local controller_methods = assert(hs.getObjectMetatable("hs.webview.usercontent"))
	for _, name in ipairs({ "windowCallback", "delete", "evaluateJavaScript", "hswindow", "deleteOnClose" }) do
		native[name] = assert(view_methods[name])
	end
	native.setCallback = assert(controller_methods.setCallback)
	local ports = { "adapters.program_providers", "adapters.apple_shortcuts_native" }
	local saved = {}
	for _, name in ipairs(ports) do saved[name] = package.loaded[name] end
	package.loaded[ports[1]] = { create = function()
		return { discover = function() return { unavailable = true } end,
			resolve = function() error("diagnostic must not resolve a user program") end,
			invalidate = function() return true end }
	end }
	package.loaded[ports[2]] = { create = function()
		return { discover = function(callback) callback({ choices = {}, truncated = false }); return true end,
			invalidate = function() return true end }
	end }
	local Picker = require("ui.action_picker")
	local UI = require("ui.ui_builder")
	local Pool = require("ui.webview_controller_pool")
	local Scheduler = require("adapters.timer_scheduler")
	local I18n = require("infra.i18n")
	I18n.init()
	for fn, suffix in pairs({ [Picker.open] = "/macos/ui/action_picker/init.lua",
		[Pool.new] = "/macos/ui/webview_controller_pool.lua", [UI.show_webview] = "/macos/ui/ui_builder.lua",
		[Scheduler.activeCount] = "/macos/adapters/timer_scheduler.lua" }) do
		assert(debug.getinfo(fn, "S").source == "@" .. root .. suffix, "foreign production owner")
	end
	local Json = require("json")
	local Result = require("adapters.webview_result")
	local state = { entries = {}, timers = {}, evaluations = {}, errors = {}, finished = false }
	local baseline, started = Scheduler.activeCount(), hs.timer.absoluteTime()
	local finish
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
			assert((hs.timer.absoluteTime() - started) / 1e9 < 35, "ActionPicker native deadline exceeded")
			if condition() then body() else await(condition, body) end
		end)
	end
	local receipt = {}
	finish = function()
		if state.finished then return end
		state.finished = true
		for timer in pairs(state.timers) do
			local ok, ack = pcall(function() return timer:stop() end)
			if not ok or not rawequal(ack, timer) then state.errors[#state.errors + 1] = "probe timer stop refused" end
		end
		state.timers = {}
		for _, name in ipairs(ports) do package.loaded[name] = saved[name] end
		receipt.schema_version, receipt.contract = 1, "native.action-picker-controller-pool"
		receipt.observation = "private source-pinned observer; read-only Lua upvalue inspection"
		receipt.nonce, receipt.source_revision = config.nonce, config.source_revision
		receipt.source_manifest_digest = config.source_manifest_digest
		receipt.pid, receipt.version, receipt.arch = hs.processInfo.processID, hs.processInfo.version, hs.processInfo.arch
		receipt.status, receipt.errors = #state.errors == 0 and "ok" or "error", state.errors
		receipt.native_input = "not attempted; no physical input, synthetic key or AppleEvent"
		receipt.business_scope = "program and automation discovery controlled; no user assignment executed"
		receipt.ucc_userdata_gc = "unmeasured; actual controller deliberately retained"
		receipt.native_apis_unmodified = rawequal(hs.webview.new, native.view_new)
			and rawequal(hs.webview.usercontent.new, native.controller_new)
			and rawequal(controller_methods.setCallback, native.setCallback)
		for _, name in ipairs({ "windowCallback", "delete", "evaluateJavaScript", "hswindow", "deleteOnClose" }) do
			if not rawequal(view_methods[name], native[name]) then receipt.native_apis_unmodified = false end
		end
		receipt.business_ports_restored = true
		for _, name in ipairs(ports) do
			if not rawequal(package.loaded[name], saved[name]) then receipt.business_ports_restored = false end
		end
		receipt.product_timer_baseline, receipt.product_timer_final = baseline, Scheduler.activeCount()
		done(receipt, state.evaluations)
	end
	local deadline = assert(hs.timer.doAfter(35, function()
		guarded(function() error("ActionPicker native deadline exceeded") end)
	end))
	state.timers[deadline] = true
	hs.shutdownCallback = function() Picker.close() end
	local function open(phase)
		local entry = { phase = phase, confirmations = 0, id = "native_probe_" .. phase .. "_" .. config.nonce,
			weak = setmetatable({}, { __mode = "v" }) }
		state.entries[#state.entries + 1] = entry
		do
			local sentinel = { phase = phase }
			local callback = function(id, parameter)
				guarded(function()
					assert(sentinel.phase == phase and id == entry.id and parameter == nil, "foreign business confirmation")
					entry.confirmations = entry.confirmations + 1
					assert(entry.confirmations == 1, "duplicate business confirmation")
				end)
				return false -- Observe the real page without assigning or launching an action.
			end
			entry.weak.callback, entry.weak.sentinel = callback, sentinel
			assert(Picker.open({ title = "ActionPicker native " .. phase .. " " .. config.nonce,
				label = "Owned native diagnostic", current = "none",
				items = { { type = "action", id = entry.id, label = entry.id } } }, callback) == true,
				"actual ActionPicker open refused")
		end
		local observed = Observer.snapshot(Picker, "@" .. root .. "/macos/ui/action_picker/init.lua")
		entry.view, entry.controller = observed.view, observed.controller
		local window = assert(entry.view:hswindow())
		entry.host_pid, entry.window_id = window:application():pid(), window:id()
		assert(entry.host_pid == hs.processInfo.processID and math.type(entry.window_id) == "integer"
			and entry.window_id > 0, "native window identity unavailable")
		assert(entry.view:deleteOnClose() == false and entry.view:allowNewWindows() == false,
			"actual picker native policy differs")
		collectgarbage("collect"); collectgarbage("collect")
		assert(entry.weak.callback ~= nil and entry.weak.sentinel ~= nil, "healthy callback retention control absent")
		return entry, window
	end
	local function confirm(entry, after)
		local function ready()
			entry.view:evaluateJavaScript("Boolean(typeof doConfirm === 'function' && typeof isConfirmable === 'function'"
				.. " && isConfirmable(" .. Json.quote(entry.id) .. "))", function(value, failure)
				guarded(function()
					state.evaluations[#state.evaluations + 1] = { phase = entry.phase, kind = "ready",
						value_type = type(failure), metatable_type = type(getmetatable(failure)),
						result_type = type(value), result = value, value = failure }
					assert(not Result.is_error(failure) and type(value) == "boolean", "frontend readiness evaluation failed")
					if value ~= true then later(ready); return end
					Observer.post_registered_action(entry, entry.id, function(accepted, detail, evaluation)
						guarded(function()
							evaluation.phase, evaluation.kind = entry.phase, "confirm"
							state.evaluations[#state.evaluations + 1] = evaluation
							assert(accepted, tostring(detail))
							entry.javascript_completed = true
						end)
					end)
					await(function() return entry.confirmations == 1 and entry.javascript_completed end, after)
				end)
			end)
		end
		await(function() return entry.view:isVisible() == true end, ready)
	end
	local function close(entry, window, after)
		assert(window:close() == true, "actual AX close refused; no public delete fallback")
		entry.ax_close_ack = true
		await(function()
			collectgarbage("collect"); collectgarbage("collect")
			return getmetatable(entry.view) == nil and entry.weak.callback == nil and entry.weak.sentinel == nil
				and Scheduler.activeCount() == baseline
		end, function()
			assert(entry.confirmations == 1, "retired callback executed again")
			receipt[entry.phase] = { window_id = entry.window_id, host_pid = entry.host_pid,
				visible_before = true, native_policy_observed = true, retained_before = true,
				business_confirmations = entry.confirmations, expected_id_received = true,
				javascript_completed = entry.javascript_completed == true,
				ax_close_ack = entry.ax_close_ack, userdata_consumed = true,
				callback_collected = true, sentinel_collected = true, product_timer_retired = true }
			after()
		end)
	end
	guarded(function()
		local a, window_a = open("a")
		confirm(a, function()
			close(a, window_a, function()
				receipt.a_retired_before_b_open = true
				local b, window_b = open("b")
				assert(not rawequal(a.view, b.view), "B reused consumed view userdata")
				assert(rawequal(a.controller, b.controller), "ActionPicker did not reuse its exact native UCC")
				receipt.same_ucc_exact, receipt.distinct_views = true, true
				confirm(b, function()
					assert(a.confirmations == 1 and a.weak.callback == nil and getmetatable(a.view) == nil,
						"B confirmation revived or invoked A")
					close(b, window_b, function()
						receipt.a_confirmation_count_unchanged = true
						assert(Picker.close() == true, "settled picker close was not idempotent")
						finish()
					end)
				end)
			end)
		end)
	end)
	return state
end

return M
