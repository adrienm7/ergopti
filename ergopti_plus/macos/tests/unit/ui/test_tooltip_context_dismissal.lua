--- tests/unit/ui/test_tooltip_context_dismissal.lua

--- ==============================================================================
--- MODULE: Tooltip Context-Dismissal Regression Tests
--- DESCRIPTION:
--- Exercises the production LLM tooltip with observable Space and focused-window
--- watchers. A preview belongs to the exact desktop/window where it was painted;
--- context changes must cancel it even when no keyboard or pointer event occurs.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"adapters.event_provenance",
	"adapters.key_state",
	"adapters.synthetic_input",
	"adapters.timer_scheduler",
	"ui.tooltip.config",
	"ui.tooltip.renderer",
	"ui.tooltip.tooltip_llm",
}

--- Builds one start/stop watcher whose callback can be fired by the test.
--- @param callback function Native callback.
--- @param faults table|nil Native result controls.
--- @return table watcher
local function make_watcher(callback, faults)
	local watcher = {
		callback = callback,
		running = false,
		started = 0,
		stopped = 0,
	}
	function watcher:start(events)
		self.events = events
		self.started = self.started + 1
		local mode = faults and faults.start_mode or "true"
		if mode == "throw" then error("simulated context watcher start failure") end
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		self.running = true
		return self
	end
	function watcher:stop()
		self.stopped = self.stopped + 1
		local modes = faults and faults.stop_modes or nil
		local mode = modes and modes[self.stopped] or "true"
		if mode == "throw" then error("simulated context watcher stop failure") end
		if mode == "false" then return false end
		if mode == "nil" then return nil end
		self.running = false
		return self
	end
	function watcher:fire(...)
		if self.running then return self.callback(...) end
	end
	return watcher
end

--- Runs one fixture with the real tooltip and native context watcher doubles.
--- @param callback function Receives fixture state.
--- @param faults table|nil Fault controls keyed by `space` or `window`.
local function with_context_fixture(callback, faults)
	helpers.with_fresh_modules(OWNED_MODULES, function()
		local previous_spaces = hs.spaces
		local previous_uielement = hs.uielement
		local previous_focused_window = hs.window.focusedWindow

		local space_watchers = {}
		local window_watchers = {}
		local focused_window = {}
		function focused_window:newWatcher(native_callback)
			local watcher = make_watcher(native_callback, faults and faults.window)
			window_watchers[#window_watchers + 1] = watcher
			return watcher
		end

		hs.spaces = {
			watcher = {
				new = function(native_callback)
					local watcher = make_watcher(native_callback, faults and faults.space)
					space_watchers[#space_watchers + 1] = watcher
					return watcher
				end,
			},
		}
		hs.uielement = { watcher = { elementDestroyed = "elementDestroyed" } }
		hs.window.focusedWindow = function() return focused_window end

		local renderer = {
			ELEM_INFO = 6,
			canvas = { minimumTextSize = function() return { w = 100, h = 20 } end },
			render = function(_content, _state, on_shown)
				if type(on_shown) == "function" then on_shown() end
				return true
			end,
			hide = function() return true end,
			set_element_text = function() return true end,
		}
		package.loaded["ui.tooltip.renderer"] = renderer

		local Config = require("ui.tooltip.config")
		Config.settings.llm_timeout_sec = 0
		local Tooltip = require("ui.tooltip.tooltip_llm")

		local outcome = table.pack(xpcall(function()
			callback({
				focused_window = focused_window,
				space_watchers = space_watchers,
				window_watchers = window_watchers,
				tooltip = Tooltip,
			})
		end, debug.traceback))

		Tooltip.hide_silent()
		hs.spaces = previous_spaces
		hs.uielement = previous_uielement
		hs.window.focusedWindow = previous_focused_window
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("tooltip_llm context lifetime", function()
	helpers.it("(HS-062) dismisses an infinite preview on Space change or window close", function()
		with_context_fixture(function(context)
			local cancel_calls = 0
			context.tooltip.set_cancel_callback(function()
				cancel_calls = cancel_calls + 1
				return true
			end)

			helpers.assert_true(context.tooltip.show_predictions({ "prediction" }, 1, true))
			helpers.assert_eq(#context.space_watchers, 1,
				"showing a preview must acquire one active-Space watcher")
			helpers.assert_eq(#context.window_watchers, 1,
				"showing a preview must observe destruction of its focused window")
			helpers.assert_eq(context.window_watchers[1].events, { "elementDestroyed" })
			helpers.assert_true(context.tooltip.is_visible())

			context.space_watchers[1]:fire(2)
			helpers.assert_true(not context.tooltip.is_visible(),
				"a Space transition must immediately revoke the preview")
			helpers.assert_eq(cancel_calls, 1,
				"Space dismissal must clear the prediction engine through its cancel port")
			helpers.assert_eq(context.space_watchers[1].stopped, 1,
				"Space dismissal must release its own native observer")
			helpers.assert_eq(context.window_watchers[1].stopped, 1,
				"Space dismissal must also release the sibling window observer")

			helpers.assert_true(context.tooltip.show_predictions({ "replacement" }, 1, true))
			helpers.assert_eq(#context.window_watchers, 2,
				"the replacement preview must own a fresh window observer")
			context.space_watchers[1].callback(3)
			helpers.assert_true(context.tooltip.is_visible(),
				"a queued callback from the stopped Space owner must not dismiss its successor")
			helpers.assert_eq(cancel_calls, 1,
				"stale context callbacks must be generation-fenced before cancellation")
			context.window_watchers[2]:fire(
				context.focused_window, "elementDestroyed", {})
			helpers.assert_true(not context.tooltip.is_visible(),
				"destroying the source window must immediately revoke the preview")
			helpers.assert_eq(cancel_calls, 2,
				"window dismissal must clear the prediction engine through its cancel port")
			helpers.assert_eq(context.space_watchers[2].stopped, 1,
				"window dismissal must release the sibling Space observer")
			helpers.assert_eq(context.window_watchers[2].stopped, 1,
				"window dismissal must release its own native observer")
		end)
	end)

	helpers.it("fails closed on context-watcher start and cleanup refusals", function()
		for _, mode in ipairs({ "false", "nil", "throw" }) do
			with_context_fixture(function(context)
				context.tooltip.set_cancel_callback(function() return true end)
				helpers.assert_eq(
					context.tooltip.show_predictions({ "prediction" }, 1, true), false,
					mode .. " Space-watcher start refusal must reject the complete render")
				helpers.assert_true(not context.tooltip.is_visible(),
					mode .. " start refusal must leave no actionable preview")
				helpers.assert_eq(#context.space_watchers, 1,
					mode .. " case must reach the native Space boundary")
				helpers.assert_true(context.space_watchers[1].stopped >= 1,
					mode .. " start refusal must roll back possible native ownership")
			end, { space = { start_mode = mode } })
		end

		with_context_fixture(function(context)
			context.tooltip.set_cancel_callback(function() return true end)
			helpers.assert_true(context.tooltip.show_predictions({ "first" }, 1, true))
			context.space_watchers[1]:fire(2)
			helpers.assert_true(not context.tooltip.is_visible(),
				"pixels must hide even while native watcher cleanup remains pending")

			helpers.assert_eq(
				context.tooltip.show_predictions({ "successor" }, 1, true), false,
				"unsettled context cleanup must block a duplicate observer transaction")
			helpers.assert_eq(#context.space_watchers, 1,
				"cleanup refusal must not acquire a second Space watcher")
			helpers.assert_eq(#context.window_watchers, 1,
				"cleanup refusal must not acquire a second window watcher")
		end, {
			space = { stop_modes = { "false", "false", "true" } },
		})
	end)
end)
