-- tools/diagnostics/macos_layout_manager_pool.lua
-- Actual LayoutManager/ControllerPool observation. Only registry business ports
-- are controlled. Private observation never replaces a native or product API.
local M = {}

function M.run(config, done)
	assert(type(config) == "table" and type(done) == "function")
	local root = assert(config.production_root)
	assert(config.expected_version == hs.processInfo.version and type(config.nonce) == "string")
	package.path = root .. "/macos/?.lua;" .. root .. "/macos/?/init.lua;"
		.. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path
	local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
	local Observer = assert(dofile(directory .. "/macos_layout_manager_pool_observer.lua"))
	local Logger = require("infra.logger")
	local policy = assert(io.open(root .. "/_shared/modules/diagnostics/redaction.json", "rb"))
	local raw_policy = assert(policy:read("*a")); assert(policy:close())
	Logger.initialize_privacy(raw_policy)
	assert(package.loaded["ui.layout_manager"] == nil, "LayoutManager already loaded")
	assert(package.loaded["ui.webview_controller_pool"] == nil, "ControllerPool already loaded")
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
	local state = { entries = {}, timers = {}, evaluations = {}, errors = {}, finished = false, phase = "starting" }
	local port = "modules.keymap.layout_registry"
	local saved = package.loaded[port]
	local Host
	package.loaded[port] = {
		snapshot = function() return { platform = "macos", index = { layouts = {} }, installed = {},
			provided = {}, builtin = {}, active = "", busy = false } end,
		refresh = function(callback)
			local entry = assert(state.current, "registry refresh outside an active phase")
			entry.refreshes = entry.refreshes + 1
			if entry.expect_native then
				assert(entry.native_message == nil, "duplicate native refresh observation")
				entry.native_message = Observer.native_message(Host, root)
			end
			callback()
		end,
		install = function() error("native diagnostic must not install a layout") end,
		uninstall = function() error("native diagnostic must not uninstall a layout") end,
		select = function() error("native diagnostic must not select a layout") end,
	}
	Host = require("ui.layout_manager")
	local UI, Pool = require("ui.ui_builder"), require("ui.webview_controller_pool")
	local Scheduler, Result = require("adapters.timer_scheduler"), require("adapters.webview_result")
	require("infra.i18n").init()
	for fn, suffix in pairs({ [Host.open] = "/macos/ui/layout_manager/init.lua",
		[Pool.new] = "/macos/ui/webview_controller_pool.lua", [UI.show_webview] = "/macos/ui/ui_builder.lua",
		[Scheduler.activeCount] = "/macos/adapters/timer_scheduler.lua" }) do
		assert(debug.getinfo(fn, "S").source == "@" .. root .. suffix, "foreign production owner")
	end
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
			assert((hs.timer.absoluteTime() - started) / 1e9 < 35, "LayoutManager native deadline exceeded")
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
		package.loaded[port] = saved
		receipt.schema_version, receipt.contract = 1, "native.layout-manager-controller-pool"
		receipt.observation = "private source-pinned observer; read-only Lua upvalue inspection"
		receipt.native_identity = "private read-only dispatch stack; raw native name and exact webView observed"
		receipt.weak_scope = "per-window lease receiver and domain; pooled dispatcher retained"
		receipt.nonce, receipt.source_revision = config.nonce, config.source_revision
		receipt.source_manifest_digest = config.source_manifest_digest
		receipt.pid, receipt.version, receipt.arch = hs.processInfo.processID, hs.processInfo.version, hs.processInfo.arch
		receipt.status, receipt.errors = #state.errors == 0 and "ok" or "error", state.errors
		receipt.native_input = "not attempted; no physical input, synthetic key or AppleEvent"
		receipt.business_scope = "registry snapshot and refresh controlled; no TIS, install, select or network"
		receipt.ucc_userdata_gc = "unmeasured; actual controller deliberately retained"
		receipt.native_apis_unmodified = rawequal(hs.webview.new, native.view_new)
			and rawequal(hs.webview.usercontent.new, native.controller_new)
			and rawequal(controller_methods.setCallback, native.setCallback)
		for _, name in ipairs({ "windowCallback", "delete", "evaluateJavaScript", "hswindow", "deleteOnClose" }) do
			if not rawequal(view_methods[name], native[name]) then receipt.native_apis_unmodified = false end
		end
		receipt.business_ports_restored = rawequal(package.loaded[port], saved)
		receipt.product_timer_baseline, receipt.product_timer_final = baseline, Scheduler.activeCount()
		if #state.errors > 0 then
			receipt.failure_observation = { phase = state.phase, entries = {} }
			for _, entry in ipairs(state.entries) do
				receipt.failure_observation.entries[#receipt.failure_observation.entries + 1] = {
					phase = entry.phase, refreshes = entry.refreshes, ax_close_ack = entry.ax_close_ack == true,
					javascript_completed = entry.javascript_completed == true,
					userdata_consumed = entry.view ~= nil and getmetatable(entry.view) == nil,
					receiver_collected = entry.weak ~= nil and entry.weak.receiver == nil,
					domain_collected = entry.weak ~= nil and entry.weak.domain == nil,
				}
			end
		end
		done(receipt, state.evaluations)
	end
	state.timers[assert(hs.timer.doAfter(35, function()
		guarded(function() error("LayoutManager native deadline exceeded") end)
	end))] = true
	local function open(phase)
		state.phase = "open_" .. phase
		local entry = { phase = phase, refreshes = 0 }
		state.current = entry
		state.entries[#state.entries + 1] = entry
		assert(Host.open() == true, "actual LayoutManager open refused")
		local observed = Observer.snapshot(Host, root)
		entry.view, entry.controller, entry.weak = observed.view, observed.controller, observed.weak
		local window = assert(entry.view:hswindow())
		entry.host_pid, entry.window_id = window:application():pid(), window:id()
		assert(entry.host_pid == hs.processInfo.processID and math.type(entry.window_id) == "integer"
			and entry.window_id > 0, "native window identity unavailable")
		assert(entry.view:deleteOnClose() == false and entry.view:allowNewWindows() == false,
			"actual layout native policy differs")
		collectgarbage("collect"); collectgarbage("collect")
		assert(entry.weak.receiver ~= nil and entry.weak.domain ~= nil, "healthy business retention absent")
		return entry, window
	end
	local function refresh(entry, after)
		state.phase = "ready_" .. entry.phase
		await(function()
			return entry.view:isVisible() == true and Observer.snapshot(Host, root).ready == true
				and entry.refreshes == 1 and Scheduler.activeCount() == baseline
		end, function()
			state.phase = "refresh_" .. entry.phase
			entry.expect_native = true
			entry.view:evaluateJavaScript("const button=document.getElementById('btn-refresh');"
				.. " if(!button || button.disabled) throw new Error('Refresh unavailable'); button.click(); true",
				function(value, failure)
					guarded(function()
						state.evaluations[#state.evaluations + 1] = { phase = entry.phase, kind = "refresh",
							value_type = type(failure), metatable_type = type(getmetatable(failure)),
							result_type = type(value), result = value, value = failure }
						assert(not Result.is_error(failure) and value == true, "native refresh completion refused")
						entry.javascript_completed = true
					end)
				end)
			await(function() return entry.refreshes == 2 and entry.javascript_completed end, after)
		end)
	end
	local function close(entry, window, after)
		state.phase = "close_" .. entry.phase
		assert(window:close() == true, "actual AX close refused; no public delete fallback")
		entry.ax_close_ack = true
		await(function()
			collectgarbage("collect"); collectgarbage("collect")
			return getmetatable(entry.view) == nil and entry.weak.receiver == nil and entry.weak.domain == nil
				and Scheduler.activeCount() == baseline
		end, function()
			assert(entry.refreshes == 2, "retired business owner executed again")
			receipt[entry.phase] = { window_id = entry.window_id, host_pid = entry.host_pid,
				visible_before = true, native_policy_observed = true, retained_before = true,
				business_refreshes = entry.refreshes, javascript_completed = entry.javascript_completed == true,
				ax_close_ack = entry.ax_close_ack, userdata_consumed = true, receiver_collected = true,
				domain_collected = true, product_timer_retired = true }
			receipt[entry.phase].native_message = assert(entry.native_message)
			after()
		end)
	end
	guarded(function()
		local a, window_a = open("a")
		refresh(a, function()
			close(a, window_a, function()
				receipt.a_retired_before_b_open = true
				local b, window_b = open("b")
				assert(not rawequal(a.view, b.view), "B reused consumed view userdata")
				assert(rawequal(a.controller, b.controller), "LayoutManager did not reuse its exact native UCC")
				receipt.same_ucc_exact, receipt.distinct_views = true, true
				refresh(b, function()
					assert(a.refreshes == 2 and a.weak.receiver == nil and a.weak.domain == nil
						and getmetatable(a.view) == nil, "B revived retired A")
					close(b, window_b, function()
						receipt.a_refresh_count_unchanged = true
						state.current, state.phase = nil, "complete"
						finish()
					end)
				end)
			end)
		end)
	end)
	return state
end

return M
