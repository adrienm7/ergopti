--- tests/unit/modules/keymap/test_control_sentinels.lua

--- ==============================================================================
--- MODULE: Regression — Karabiner control sentinels have one owner
---         (sentinel-never-reaches-app)
--- DESCRIPTION:
--- Karabiner prepends an F20 key event to every action that enters the
--- navigation layer so Hammerspoon can tell layer entry from typing. Every
--- Ergopti eventtap let that F20 pass through, so the frontmost application
--- received it: in a QSpace rename field it replaced the selected file name the
--- moment the user held left Command for the navigation layer.
---
--- ROOT CAUSE ENCODED: the sentinel had observers but no owner. The production
--- keymap taps now delete it (test_synthetic_provenance_interleaving.lua); these
--- cases pin the owner's claim/publish contract and prove that the tooltip
--- watchers, which may run before or after the keymap tap, neither act on the
--- raw key nor lose the signal.
--- ==============================================================================

local helpers = require("tests.helpers")
local TooltipSupport = require("tests.support.tooltip_watcher_fixture")

local KEYCODE_A = 0
local KEYCODE_F20 = 90


--- Loads a fresh owner whose deferred diagnostics are captured.
--- @return table sentinels
--- @return table deferred Captured deferred callbacks.
--- @return table logs Captured error lines.
local function load_owner()
	local deferred, logs = {}, {}
	return helpers.with_stub_scope({
		"modules.keymap.control_sentinels",
		"adapters.synthetic_input",
		"infra.logger",
	}, function()
		local logger = helpers.make_logger_stub()
		logger.error = function(_, format, ...) logs[#logs + 1] = string.format(format, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.synthetic_input"] = {
			defer_after_callback = function(_label, callback)
				deferred[#deferred + 1] = callback
				return true
			end,
		}
		package.loaded["modules.keymap.control_sentinels"] = nil
		return require("modules.keymap.control_sentinels"), deferred, logs
	end)
end


helpers.describe("control sentinels: one owner claims the Karabiner F20", function()
	helpers.it("(sentinel-never-reaches-app) claims both F20 phases and publishes once per press", function()
		local Sentinels = load_owner()
		local signals = {}
		Sentinels.set_listener("test.observer", function(signal) signals[#signals + 1] = signal end)

		helpers.assert_true(Sentinels.claim_key(KEYCODE_F20, true), "F20 key-down must be deleted")
		helpers.assert_true(Sentinels.claim_key(KEYCODE_F20, false), "F20 key-up must be deleted")
		helpers.assert_eq(#signals, 1, "only the key-down edge publishes the signal")
		helpers.assert_eq(signals[1], Sentinels.NAV_LAYER_ENTERED)

		helpers.assert_true(not Sentinels.claim_key(KEYCODE_A, true), "ordinary keys are never claimed")
		helpers.assert_true(not Sentinels.claim_key(KEYCODE_A, false))
		helpers.assert_eq(#signals, 1, "ordinary keys publish nothing")
	end)

	helpers.it("(sentinel-never-reaches-app) isolates a failing listener and reports it off the tap", function()
		local Sentinels, deferred, logs = load_owner()
		local healthy = 0
		Sentinels.set_listener("test.failing", function() error("listener exploded") end)
		Sentinels.set_listener("test.healthy", function() healthy = healthy + 1 end)

		helpers.assert_true(Sentinels.claim_key(KEYCODE_F20, true),
			"a listener failure must never let the sentinel leak to the application")
		helpers.assert_eq(healthy, 1, "one failing listener must not starve the others")
		helpers.assert_eq(#logs, 0, "logging must not run inside the eventtap callback")
		helpers.assert_eq(#deferred, 1, "the failure report must be deferred off the tap")
		deferred[1]()
		helpers.assert_true(#logs == 1 and logs[1]:find("test.failing", 1, true) ~= nil,
			"the failing listener must be reported by name")

		Sentinels.set_listener("test.failing", nil)
		Sentinels.claim_key(KEYCODE_F20, true)
		helpers.assert_eq(healthy, 2)
		helpers.assert_eq(#deferred, 1, "an unregistered listener must stop receiving signals")
	end)
end)


helpers.describe("control sentinels: tooltip watchers defer to the owner", function()
	helpers.it("(sentinel-never-reaches-app) LLM tooltip ignores raw F20 and restarts its deadline on the signal", function()
		TooltipSupport.with_fixture(function(fixture)
			local context = fixture.load_tooltip(TooltipSupport.CASES[1])
			helpers.assert_eq(TooltipSupport.CASES[1].render(context.tooltip), true)
			local first_deadline = TooltipSupport.running_timers(context.timers)[1]
			helpers.assert_not_nil(first_deadline, "the rendered tooltip must own an idle deadline")

			-- Quartz order is not stable: this watcher may see F20 before the keymap
			-- owner deletes it. It must neither consume nor dismiss on the raw key.
			local key_watcher = context.created[#context.created]
			helpers.assert_eq(key_watcher.fn(TooltipSupport.hardware_key_event(KEYCODE_F20)), false,
				"the tooltip watcher must leave the sentinel to its owner")
			TooltipSupport.drain_deferred_actions(context.timers)
			helpers.assert_true(context.tooltip.is_visible(),
				"entering the navigation layer must not dismiss the tooltip")
			helpers.assert_true(first_deadline.running,
				"the raw key must not be what renews the deadline")

			helpers.assert_true(require("modules.keymap.control_sentinels").claim_key(KEYCODE_F20, true))
			TooltipSupport.drain_deferred_actions(context.timers)
			helpers.assert_true(context.tooltip.is_visible())
			local live = TooltipSupport.running_timers(context.timers)
			helpers.assert_eq(#live, 1, "exactly one idle deadline must remain")
			helpers.assert_true(live[1] ~= first_deadline,
				"the owner's navigation-layer signal must restart the idle deadline")
		end)
	end)

	helpers.it("(sentinel-never-reaches-app) hotstring tooltip ignores raw F20 without hiding", function()
		TooltipSupport.with_fixture(function(fixture)
			local context = fixture.load_tooltip(TooltipSupport.CASES[2])
			helpers.assert_eq(TooltipSupport.CASES[2].render(context.tooltip), true)
			local key_watcher = context.created[#context.created]
			helpers.assert_eq(key_watcher.fn(TooltipSupport.hardware_key_event(KEYCODE_F20)), false,
				"the hotstring watcher must leave the sentinel to its owner")
			TooltipSupport.drain_deferred_actions(context.timers)
			helpers.assert_true(context.renderer.visible,
				"the navigation-layer sentinel is not a dismissing keystroke")
		end)
	end)
end)
