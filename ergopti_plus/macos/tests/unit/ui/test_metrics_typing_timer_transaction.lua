--- tests/unit/ui/test_metrics_typing_timer_transaction.lua

--- ==============================================================================
--- MODULE: Typing Metrics Timer Transaction Tests
--- DESCRIPTION:
--- Proves that the dashboard does not report a usable window when its bootstrap
--- or request-poll capabilities refuse activation, and that closed-window timer
--- callbacks cannot mutate a newer UI generation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Scope = require("tests.support.metrics_typing_scope")

local load_dashboard = require("tests.support.metrics_typing_fixture")
helpers.describe("typing metrics startup timer transaction", function()
	Scope.it("refuses before publishing a window when ingest subscription fails", function()
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

	Scope.it("deletes the window when delayed-paint acquisition throws or returns nil", function()
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

	Scope.it("deletes the window when the first delayed paint is uncommitted", function()
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

	Scope.it("rolls back the delayed paint when the recurring poller refuses", function()
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

	Scope.it("generation-fences queued paint and poll callbacks after close", function()
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

	Scope.it("continues first paint while retaining one-shot stop debt", function()
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

	Scope.it("retains the exact focused dashboard when native deletion raises", function()
		local controls = {delete_throws = false, focused = true}
		local scheduler = {
			after = function() return {timer = {}}, true end,
			every = function() return {timer = {}}, true end,
			cancel = function(handle) handle.timer = nil; return true end,
		}
		local dashboard, context = load_dashboard(scheduler, nil, controls)
		helpers.assert_true(dashboard.show())
		controls.delete_throws = true

		helpers.assert_eq(dashboard.show(), false,
			"a throwing native delete must refuse logical dashboard closure")
		helpers.assert_true(dashboard._wv == context.webview,
			"the exact focused dashboard must remain owned after refusal")
		helpers.assert_eq(context.webviews_created, 1)

		controls.delete_throws = false
		helpers.assert_true(dashboard.show(),
			"the exact retained dashboard must remain retryable")
		helpers.assert_nil(dashboard._wv)
		helpers.assert_eq(context.deleted, 2)
		helpers.assert_true(dashboard.show())
		helpers.assert_eq(context.webviews_created, 2,
			"a successor may open only after exact native deletion")
	end)

	Scope.it("retains a startup window whose rollback deletion raises", function()
		local controls = {delete_throws = true}
		local scheduler = {
			after = function() error("synthetic bootstrap timer refusal") end,
			every = function() error("poller must not start") end,
			cancel = function() error("no timer owner should exist") end,
		}
		local dashboard, context = load_dashboard(scheduler, nil, controls)

		helpers.assert_eq(dashboard.show(), false)
		helpers.assert_true(dashboard._startup_webview == context.webview,
			"a refused rollback must retain the exact unpublished WebView")
		helpers.assert_eq(dashboard.show(), false,
			"reopen must refuse while exact startup cleanup remains pending")
		helpers.assert_eq(context.webviews_created, 1,
			"startup cleanup debt must block a successor WebView")

		controls.delete_throws = false
		helpers.assert_eq(dashboard.close(), true,
			"explicit close must retry the exact startup WebView")
		helpers.assert_nil(dashboard._startup_webview)
		helpers.assert_eq(context.deleted, 3)
	end)
end)
