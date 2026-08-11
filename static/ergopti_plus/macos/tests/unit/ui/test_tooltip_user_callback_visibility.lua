--- tests/unit/ui/test_tooltip_user_callback_visibility.lua

--- ==============================================================================
--- MODULE: Tooltip User Callback Visibility Regression Tests
--- DESCRIPTION:
--- Exercises the real LLM tooltip with observable renderer, timer, eventtap, and
--- logger boundaries. Exceptions from caller-supplied navigation and cancellation
--- callbacks must reach the file logger, fail the public action, and still close
--- every UI owner so stale pixels cannot remain actionable.
--- ==============================================================================

local helpers = require("tests.helpers")

local IDLE_TIMEOUT_SEC = 10

--- Returns whether one captured log entry contains the requested text.
--- @param entries table Captured formatted log entries.
--- @param needle string Expected substring.
--- @return boolean found
local function log_contains(entries, needle)
	for _, entry in ipairs(entries) do
		if tostring(entry):find(needle, 1, true) then return true end
	end
	return false
end

--- Returns every timer whose test-double state is currently active.
--- @param timers table Timer objects.
--- @return table active
local function running_timers(timers)
	local active = {}
	for _, timer in ipairs(timers) do
		if timer.running then active[#active + 1] = timer end
	end
	return active
end

--- Finds the live positive-delay idle deadline.
--- @param timers table Timer objects.
--- @return table|nil timer
local function find_idle_timer(timers)
	for _, timer in ipairs(running_timers(timers)) do
		if type(timer.delay) == "number" and timer.delay > 0 then return timer end
	end
	return nil
end

--- Loads the real tooltip with faithful observable UI and logger boundaries.
--- @return table context
local function load_tooltip()
	local Config = helpers.load_with_stubs("ui.tooltip.config")
	Config.settings.llm_timeout_sec = IDLE_TIMEOUT_SEC

	package.loaded["adapters.event_provenance"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_tap_guard"] = nil

	local renderer
	renderer = {
		visible = false,
		hide_calls = 0,
		canvas = {
			minimumTextSize = function() return { w = 100, h = 20 } end,
		},
		render = function(_content, _state, on_shown)
			renderer.visible = true
			if type(on_shown) == "function" then on_shown() end
			return true
		end,
		hide = function()
			renderer.visible = false
			renderer.hide_calls = renderer.hide_calls + 1
			return true
		end,
	}
	package.loaded["ui.tooltip.renderer"] = renderer

	package.loaded["infra.logger"] = nil
	local real_logger = require("infra.logger")
	local errors = {}
	local logger_spy = setmetatable({
		error = function(_log, format, ...)
			errors[#errors + 1] = string.format(tostring(format), ...)
		end,
	}, { __index = real_logger })
	package.loaded["infra.logger"] = logger_spy
	package.loaded["ui.tooltip.tooltip_llm"] = nil
	local tooltip = require("ui.tooltip.tooltip_llm")

	-- The tooltip keeps the exact spy and adapter instances it loaded. Restoring
	-- the package cache prevents this test's capture sink from leaking into later
	-- modules while preserving the live fixture's dependency graph
	package.loaded["infra.logger"] = real_logger
	package.loaded["adapters.event_provenance"] = nil
	package.loaded["adapters.synthetic_input"] = nil
	package.loaded["adapters.event_tap_guard"] = nil

	return {
		errors = errors,
		renderer = renderer,
		timers = hs.timer.__timers,
		tooltip = tooltip,
	}
end

helpers.describe("tooltip_llm: user callback failures are visible and fail closed", function()
	helpers.it("(tooltip-callback-visible) logs a cancel throw and still revokes every UI owner", function()
		local context = load_tooltip()
		context.tooltip.set_cancel_callback(function()
			error("cancel callback sentinel")
		end)
		helpers.assert_eq(context.tooltip.show_predictions({ "prediction" }, 1, true), true)
		local idle_timer = find_idle_timer(context.timers)
		helpers.assert_not_nil(idle_timer,
			"the fixture must own a real idle deadline before exercising dismissal")

		idle_timer:fire()

		helpers.assert_true(log_contains(context.errors, "Prediction cancel callback failed"),
			"the swallowed cancel exception must become an ERROR in the file logger")
		helpers.assert_true(log_contains(context.errors, "cancel callback sentinel"),
			"the ERROR must preserve the original callback exception")
		helpers.assert_true(log_contains(context.errors, "stack traceback"),
			"the ERROR must retain an actionable traceback")
		helpers.assert_true(not context.tooltip.is_visible(),
			"cancel failure must still clear logical tooltip ownership")
		helpers.assert_true(not context.renderer.visible,
			"cancel failure must still hide the physical canvas")
		helpers.assert_true(context.renderer.hide_calls >= 1,
			"fail-close must execute the physical teardown")
		helpers.assert_eq(#running_timers(context.timers), 0,
			"fail-close must leave no idle deadline behind")
	end)

	helpers.it("(tooltip-callback-visible) rejects a navigation throw and cancels the divergent selection", function()
		local context = load_tooltip()
		local cancel_calls = 0
		context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1 end)
		context.tooltip.set_navigate_callback(function()
			error("navigation callback sentinel")
		end)
		helpers.assert_eq(context.tooltip.show_predictions({ "first", "second" }, 1, true), true)

		local navigate_result = context.tooltip.navigate(1)

		helpers.assert_eq(navigate_result, false,
			"navigation must not report success when its owner callback failed")
		helpers.assert_true(log_contains(context.errors, "Prediction navigation callback failed"),
			"the swallowed navigation exception must become an ERROR in the file logger")
		helpers.assert_true(log_contains(context.errors, "navigation callback sentinel"),
			"the ERROR must preserve the original navigation exception")
		helpers.assert_true(log_contains(context.errors, "stack traceback"),
			"the ERROR must retain an actionable traceback")
		helpers.assert_eq(cancel_calls, 1,
			"navigation failure must release prediction-engine ownership exactly once")
		helpers.assert_true(not context.tooltip.is_visible(),
			"navigation failure must hide the selection that the owner never accepted")
		helpers.assert_eq(context.tooltip.get_current_index(), 1,
			"fail-close must reset the uncommitted selection")
		helpers.assert_true(not context.renderer.visible,
			"navigation failure must not leave divergent pixels actionable")
		helpers.assert_eq(#running_timers(context.timers), 0,
			"navigation failure must revoke the tooltip deadline")
	end)

	helpers.it("(tooltip-callback-visible) preserves successful navigation and cancellation", function()
		local context = load_tooltip()
		local navigated_to = nil
		local cancel_calls = 0
		context.tooltip.set_navigate_callback(function(index) navigated_to = index end)
		context.tooltip.set_cancel_callback(function() cancel_calls = cancel_calls + 1 end)
		helpers.assert_eq(context.tooltip.show_predictions({ "first", "second" }, 1, true), true)

		helpers.assert_eq(context.tooltip.navigate(1), true,
			"a successful owner callback must preserve the existing navigation contract")
		helpers.assert_eq(navigated_to, 2,
			"navigation must deliver the committed selection index")
		helpers.assert_eq(context.tooltip.get_current_index(), 2)
		helpers.assert_true(context.tooltip.is_visible(),
			"successful navigation must keep the tooltip interactive")

		local idle_timer = find_idle_timer(context.timers)
		helpers.assert_not_nil(idle_timer)
		idle_timer:fire()
		helpers.assert_eq(cancel_calls, 1,
			"successful dismissal must preserve the cancel callback contract")
		helpers.assert_true(not context.tooltip.is_visible())
		helpers.assert_eq(#context.errors, 0,
			"successful callbacks must not emit false ERROR diagnostics")
	end)
end)
