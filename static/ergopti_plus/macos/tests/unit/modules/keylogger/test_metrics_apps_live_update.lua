--- tests/unit/modules/keylogger/test_metrics_apps_live_update.lua

--- ==============================================================================
--- MODULE: Metrics Apps Window Lifecycle Transaction Tests
--- DESCRIPTION:
--- Drives the real apps dashboard through subscription refusal, partial timer
--- acquisition, native close/reopen, queued continuation delivery and delayed
--- WebKit completion. The assertions prove that one exact window generation owns
--- every asynchronous mutation and that refused timer cleanup remains retryable.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a scheduler double whose callbacks remain manually deliverable after
--- cancellation, matching a callback already queued on the native runloop.
--- @param context table Shared observation state.
--- @param options table Failure-injection options.
--- @return table scheduler TimerScheduler test double.
local function make_scheduler(context, options)
	local after_calls = 0
	return {
		after = function(delay, callback)
			after_calls = after_calls + 1
			local handle = { timer = {}, id = after_calls }
			local entry = {
				callback = callback,
				delay = delay,
				handle = handle,
				source = "scheduler",
			}
			context.timers[#context.timers + 1] = entry
			context.timer_by_handle[handle] = entry
			if options.fail_after_at == after_calls then return handle, false end
			return handle, true
		end,
		cancel = function(handle)
			context.cancel_calls[handle] = (context.cancel_calls[handle] or 0) + 1
			if options.refuse_cancel_once == handle
				and context.cancel_calls[handle] == 1
			then
				return false
			end
			handle.timer = nil
			return true
		end,
	}
end

--- Loads a fresh dashboard around controlled subscription, window and timer
--- owners. Raw timers are captured too so the pre-fix implementation exercises
--- the same behavioral scenarios instead of failing because a stub is absent.
--- @param options table|nil Failure-injection options.
--- @return table dashboard Fresh dashboard module.
--- @return table context Captured lifecycle state.
local function load_dashboard(options)
	options = options or {}
	local context = {
		cancel_calls = {},
		close_callbacks = {},
		evaluations = {},
		raw_timer_calls = 0,
		subscriptions = 0,
		timer_by_handle = {},
		timers = {},
		webkit_callbacks = {},
		webviews = {},
	}
	local scheduler = make_scheduler(context, options)

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	local fs_stub = {
		attributes = function() return true end,
		dir = function() return function() end, {} end,
	}
	package.loaded["hs.fs"] = fs_stub
	package.loaded["hs.json"] = {
		decode = function() return {} end,
		encode = function() return "{}" end,
	}
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["infra.paths"] = { shared = function() return "/shared" end }
	package.loaded["infra.dialog_util"] = {}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["adapters.file_system"] = {
		read_with_status = function() return "{}", "ok" end,
		write = function() return true end,
	}
	package.loaded["modules.keylogger.log_manager"] = {
		get_db_rev = function() return 1 end,
		get_sqlite_path = function() return "/tmp/db.sqlite" end,
		on_ingest_done = function(callback)
			context.subscriptions = context.subscriptions + 1
			context.on_ingest = callback
			if options.subscribe then return options.subscribe(callback) end
			return true
		end,
	}
	package.loaded["modules.keylogger.sqlite_reader"] = {
		read_manifest = function() return {} end,
	}
	package.loaded["modules.keylogger.context_tracker"] = {
		get_active_app_snapshot = function() return nil end,
	}

	local function new_webview(window_options)
		local webview = {
			deleted = 0,
			focused = 0,
			id = #context.webviews + 1,
		}
		function webview:bringToFront()
			self.focused = self.focused + 1
			return true
		end
		function webview:delete()
			self.deleted = self.deleted + 1
			if options.delete_throws then error("synthetic apps dashboard delete refusal") end
			return true
		end
		function webview:evaluateJavaScript(script, callback)
			context.evaluations[#context.evaluations + 1] = {
				callback = callback,
				script = script,
				webview = self,
			}
			if callback then
				context.webkit_callbacks[#context.webkit_callbacks + 1] = callback
			end
			return true
		end
		function webview:hswindow() return nil end
		function webview:show()
			self.focused = self.focused + 1
			return true
		end
		context.webviews[#context.webviews + 1] = webview
		context.close_callbacks[#context.close_callbacks + 1] = window_options.on_close
		if options.close_during_create then window_options.on_close() end
		return webview
	end

	package.loaded["ui.ui_builder"] = {
		force_focus = function(webview)
			webview.focused = webview.focused + 1
			return true
		end,
		show_webview = function(window_options)
			if options.webview_throws then error("webview exploded") end
			return new_webview(window_options)
		end,
	}
	hs_stub.application.find = function() return nil end
	hs_stub.screen.mainScreen = function()
		return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
	end
	hs_stub.timer.doAfter = function(delay, callback)
		context.raw_timer_calls = context.raw_timer_calls + 1
		local handle = { timer = {}, raw = true }
		context.timers[#context.timers + 1] = {
			callback = callback,
			delay = delay,
			handle = handle,
			source = "raw",
		}
		return handle
	end
	hs_stub.webview.usercontent.new = function()
		return {
			setCallback = function(_, callback)
				context.bridge_callback = callback
				return true
			end,
		}
	end

	package.loaded["ui.metrics_apps.init"] = nil
	return require("ui.metrics_apps.init"), context
end

--- Copies the timer entries currently owned by one generation.
--- @param context table Captured lifecycle state.
--- @return table entries Snapshot of timer entries.
local function timer_snapshot(context)
	local entries = {}
	for index, entry in ipairs(context.timers) do entries[index] = entry end
	return entries
end

helpers.describe("metrics_apps: lifecycle transaction", function()
	helpers.it("refuses before window publication when subscription throws or returns nil", function()
		for _, case in ipairs({
			{ label = "throw", subscribe = function() error("subscription exploded") end },
			{ label = "nil", subscribe = function() return nil end },
		}) do
			local dashboard, context = load_dashboard({ subscribe = case.subscribe })
			local ok, committed = pcall(dashboard.show)
			helpers.assert_true(ok, case.label .. " subscription refusal must be contained")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(context.subscriptions, 1)
			helpers.assert_eq(#context.webviews, 0,
				case.label .. " subscription refusal must precede window publication")
		end
	end)

	helpers.it("rejects a window closed reentrantly during its own construction", function()
		local dashboard, context = load_dashboard({ close_during_create = true })

		helpers.assert_eq(dashboard.show(), false)
		helpers.assert_nil(dashboard._wv,
			"a candidate closed before publication must never become the live owner")
		helpers.assert_eq(#context.timers, 0,
			"a reentrantly closed candidate must not acquire continuation timers")
	end)

	helpers.it("rolls back every exact timer and the window after partial acquisition", function()
		local dashboard, context = load_dashboard({ fail_after_at = 3 })

		helpers.assert_eq(dashboard.show(), false)
		helpers.assert_nil(dashboard._wv)
		helpers.assert_eq(context.webviews[1].deleted, 1)
		helpers.assert_eq(context.cancel_calls[context.timers[1].handle], 1,
			"the first committed timer must be rolled back")
		helpers.assert_eq(context.cancel_calls[context.timers[2].handle], 1,
			"the second committed timer must be rolled back")
		helpers.assert_eq(context.cancel_calls[context.timers[3].handle], 1,
			"the rejected exact candidate must be released")
	end)

	helpers.it("retains refused close cleanup and retries the same timer before reopen", function()
		local dashboard, context = load_dashboard()
		helpers.assert_eq(dashboard.show(), true)
		local first_handle = context.timers[1].handle
		context.timer_by_handle[first_handle] = context.timers[1]
		local original_cancel = package.loaded["adapters.timer_scheduler"].cancel
		local refused = false
		package.loaded["adapters.timer_scheduler"].cancel = function(handle)
			if handle == first_handle and not refused then
				refused = true
				context.cancel_calls[handle] = (context.cancel_calls[handle] or 0) + 1
				return false
			end
			return original_cancel(handle)
		end

		context.close_callbacks[1]()
		helpers.assert_eq(context.cancel_calls[first_handle], 1)
		helpers.assert_eq(dashboard.show(), true)
		helpers.assert_eq(context.cancel_calls[first_handle], 2,
			"reopen must retry the exact retained cleanup capability")
	end)

	helpers.it("retains the exact dashboard when native deletion raises", function()
		local options = {delete_throws = false}
		local dashboard, context = load_dashboard(options)
		helpers.assert_true(dashboard.show())
		local owned = context.webviews[1]
		options.delete_throws = true

		helpers.assert_eq(dashboard.close(), false,
			"a throwing native delete must refuse logical dashboard closure")
		helpers.assert_true(dashboard._wv == owned,
			"the exact apps dashboard must remain owned after refusal")
		helpers.assert_eq(#context.webviews, 1)

		options.delete_throws = false
		helpers.assert_true(dashboard.close(),
			"the exact retained dashboard must remain retryable")
		helpers.assert_nil(dashboard._wv)
		helpers.assert_eq(owned.deleted, 2)
		helpers.assert_true(dashboard.show())
		helpers.assert_eq(#context.webviews, 2,
			"a successor may open only after exact native deletion")
	end)

	helpers.it("retains a startup window whose rollback deletion raises", function()
		local options = {delete_throws = true, fail_after_at = 3}
		local dashboard, context = load_dashboard(options)

		helpers.assert_eq(dashboard.show(), false)
		local startup_owner = context.webviews[1]
		helpers.assert_true(dashboard._startup_webview == startup_owner,
			"a refused rollback must retain the exact unpublished WebView")
		helpers.assert_eq(dashboard.show(), false,
			"reopen must refuse while exact startup cleanup remains pending")
		helpers.assert_eq(#context.webviews, 1,
			"startup cleanup debt must block a successor WebView")

		options.delete_throws = false
		helpers.assert_eq(dashboard.close(), true,
			"explicit close must retry the exact startup WebView")
		helpers.assert_nil(dashboard._startup_webview)
		helpers.assert_eq(startup_owner.deleted, 3)
	end)

	helpers.it("generation-fences old focus timers and close callbacks after reopen", function()
		local dashboard, context = load_dashboard()
		helpers.assert_eq(dashboard.show(), true)
		local old_timers = timer_snapshot(context)
		local old_webview = context.webviews[1]
		context.close_callbacks[1]()
		helpers.assert_eq(dashboard.show(), true)
		local new_webview = context.webviews[2]
		local old_focus_count = old_webview.focused
		local new_focus_count = new_webview.focused

		for _, entry in ipairs(old_timers) do entry.callback() end
		context.close_callbacks[1]()

		helpers.assert_eq(old_webview.focused, old_focus_count,
			"queued focus callbacks must not resurrect the closed exact window")
		helpers.assert_eq(new_webview.focused, new_focus_count,
			"queued focus callbacks must not target the replacement window")
		helpers.assert_true(dashboard._wv == new_webview,
			"an old on_close callback must not clear the replacement window")
	end)

	helpers.it("rechecks identity after the WebKit yield before injecting", function()
		local dashboard, context = load_dashboard()
		helpers.assert_eq(dashboard.show(), true)
		local first_generation_timers = timer_snapshot(context)
		first_generation_timers[5].callback()
		local refresh_timer = context.timers[#context.timers]
		refresh_timer.callback()
		local stale_completion = context.webkit_callbacks[#context.webkit_callbacks]
		helpers.assert_type(stale_completion, "function",
			"the real refresh path must reach an asynchronous WebKit completion")

		context.close_callbacks[1]()
		helpers.assert_eq(dashboard.show(), true)
		local evaluations_before_stale_completion = #context.evaluations
		stale_completion("function")

		helpers.assert_eq(#context.evaluations, evaluations_before_stale_completion,
			"a completion from the closed window must not inject into its replacement")
	end)

	helpers.it("subscribes once and schedules live refresh through the owned timer adapter", function()
		local dashboard, context = load_dashboard()
		helpers.assert_eq(dashboard.show(), true)
		helpers.assert_eq(context.subscriptions, 1)
		helpers.assert_type(context.on_ingest, "function")
		helpers.assert_eq(context.on_ingest(), nil)
		helpers.assert_eq(context.raw_timer_calls, 0,
			"dashboard continuations must not bypass TimerScheduler ownership")
		helpers.assert_true(#context.timers >= 6,
			"the live ingest callback must schedule a generation-owned refresh")
	end)
end)
