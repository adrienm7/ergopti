--- tests/unit/ui/test_metrics_typing_timer_transaction.lua

--- ==============================================================================
--- MODULE: Typing Metrics Timer Transaction Tests
--- DESCRIPTION:
--- Proves that the dashboard does not report a usable window when its bootstrap
--- or request-poll capabilities refuse activation, and that closed-window timer
--- callbacks cannot mutate a newer UI generation.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh dashboard around controlled timer and webview boundaries.
--- @param scheduler table TimerScheduler test double.
--- @param subscribe function|nil Ingest-listener acquisition double.
--- @return table module Fresh dashboard module.
--- @return table context Captured UI side effects.
local function load_dashboard(scheduler, subscribe)
	local context = { deleted = 0, evaluated = 0, webviews_created = 0, on_close = nil }
	local webview = {}
	webview.delete = function() context.deleted = context.deleted + 1 end
	webview.evaluateJavaScript = function()
		context.evaluated = context.evaluated + 1
		return true
	end
	webview.hswindow = function() return nil end
	webview.bringToFront = function() end

	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["hs.fs"] = { dir = function() return function() end, {} end }
	package.loaded["hs.json"] = {
		encode = function() return "{}" end,
		decode = function() return {} end,
	}
	package.loaded["ui.ui_builder"] = {
		show_webview = function(options)
			context.webviews_created = context.webviews_created + 1
			context.on_close = options.on_close
			return webview
		end,
	}
	package.loaded["modules.keylogger.log_manager"] = {
		on_ingest_done = subscribe or function(callback)
			context.on_ingest = callback
			return true
		end,
	}

	local dashboard = helpers.load_with_stubs("ui.metrics_typing.init", {
		screen = {
			mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
			end,
		},
		window = { focusedWindow = function() return nil end },
	})
	return dashboard, context
end

helpers.describe("typing metrics startup timer transaction", function()
	helpers.it("refuses before publishing a window when ingest subscription fails", function()
		for _, case in ipairs({
			{ label = "throw", subscribe = function() error("subscription exploded") end },
			{ label = "nil", subscribe = function() return nil end },
		}) do
			local dashboard, context = load_dashboard({
				after = function() error("no timer may start without the ingest listener") end,
				every = function() error("no poller may start without the ingest listener") end,
				cancel = function() error("no cleanup handle should exist") end,
			}, case.subscribe)
			local ok, committed = pcall(dashboard.show)
			helpers.assert_true(ok,
				case.label .. " subscription failure must remain contained")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(context.webviews_created, 0,
				case.label .. " subscription failure must precede window publication")
			helpers.assert_eq(context.deleted, 0,
				case.label .. " refusal must not manufacture a partial webview")
		end
	end)

	helpers.it("deletes the window when delayed-paint acquisition throws or returns nil", function()
		for _, case in ipairs({
			{ label = "throw", after = function() error("timer constructor exploded") end },
			{ label = "nil", after = function() return nil, nil end },
		}) do
			local dashboard, context = load_dashboard({
				after = case.after,
				every = function() error("poller must not start") end,
				cancel = function() error("no continuation handle exists") end,
			})
			local ok, committed = pcall(dashboard.show)
			helpers.assert_true(ok, case.label .. " acquisition failure must not escape show()")
			helpers.assert_eq(committed, false)
			helpers.assert_eq(context.deleted, 1,
				case.label .. " acquisition failure must not leave a blank window")
		end
	end)

	helpers.it("deletes the window when the first delayed paint is uncommitted", function()
		local cancellations = 0
		local scheduler = {
			after = function() return { timer = {} }, false end,
			every = function() error("poller must not be acquired after bootstrap refusal") end,
			cancel = function(handle)
				cancellations = cancellations + 1
				handle.timer = nil
				return true
			end,
		}
		local dashboard, context = load_dashboard(scheduler)

		helpers.assert_eq(dashboard.show(), false)
		helpers.assert_eq(context.deleted, 1,
			"a dashboard with no possible first paint must not remain as a blank window")
		helpers.assert_true(cancellations >= 1,
			"the uncommitted exact continuation must be released")
	end)

	helpers.it("rolls back the delayed paint when the recurring poller refuses", function()
		local bootstrap = { timer = {} }
		local poller = { timer = {} }
		local cancelled = {}
		local scheduler = {
			after = function() return bootstrap, true end,
			every = function() return poller, false end,
			cancel = function(handle)
				cancelled[handle] = true
				handle.timer = nil
				return true
			end,
		}
		local dashboard, context = load_dashboard(scheduler)

		helpers.assert_eq(dashboard.show(), false)
		helpers.assert_eq(context.deleted, 1)
		helpers.assert_true(cancelled[bootstrap] == true,
			"poller refusal must roll back the already committed delayed paint")
		helpers.assert_true(cancelled[poller] == true,
			"poller refusal must release its exact candidate")
	end)

	helpers.it("generation-fences queued paint and poll callbacks after close", function()
		local delayed_callback = nil
		local poll_callback = nil
		local scheduler = {
			after = function(_delay, callback)
				delayed_callback = callback
				return { timer = {} }, true
			end,
			every = function(_delay, callback)
				poll_callback = callback
				return { timer = {} }, true
			end,
			cancel = function(handle) handle.timer = nil; return true end,
		}
		local dashboard, context = load_dashboard(scheduler)

		helpers.assert_eq(dashboard.show(), true)
		context.on_close()
		delayed_callback()
		poll_callback()
		helpers.assert_eq(context.evaluated, 0,
			"callbacks queued by a closed dashboard generation must be inert")
	end)

	helpers.it("continues first paint while retaining one-shot stop debt", function()
		local first_callback = nil
		local after_calls = 0
		local scheduler = {
			after = function(_delay, callback)
				after_calls = after_calls + 1
				if after_calls == 1 then first_callback = callback end
				return { timer = {} }, true
			end,
			every = function() return { timer = {} }, true end,
			cancel = function() return false end,
		}
		local dashboard = load_dashboard(scheduler)

		helpers.assert_eq(dashboard.show(), true)
		first_callback()
		helpers.assert_eq(after_calls, 2,
			"a committed bootstrap must schedule fresh data even when its fired timer retains cleanup debt")
	end)
end)
