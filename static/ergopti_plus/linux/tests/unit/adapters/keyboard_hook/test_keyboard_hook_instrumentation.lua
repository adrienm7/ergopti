--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_instrumentation.lua

--- ==============================================================================
--- MODULE: Keyboard Hook Instrumentation And Idle Wait
--- DESCRIPTION:
--- The tap-hold decisions are counted per event so a summary line reports what
--- the engine did, and the idle wait answers nil (not false) whenever the hook
--- cannot sleep on its sources, so the loop yields a fixed millisecond instead.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")

local EV_KEY = 1
local KEYS = { caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 10 } }

--- Drives physical events through a fresh hook, with or without an engine.
--- @param events table Array of { code, value }.
--- @param with_engine boolean
--- @return table perf snapshot
local function drive(events, with_engine)
	local perf = helpers.load_module("infra.perf_counters")
	perf._reset_for_test()
	local kh = helpers.load_module("adapters.keyboard_hook")
	if with_engine then
		kh.set_remapper(Engine.new({ keys = KEYS, tap_min_ms = 0, one_shot_timeout_ms = 2000 }), function() end)
	end
	local stream = {}
	for index, pair in ipairs(events) do stream[index] = { type = EV_KEY, code = pair[1], value = pair[2] } end
	kh._test_drive(stream, { onEmitRaw = function() return true end, onChar = function() end }, true)
	kh.set_remapper(nil)
	return perf.snapshot()
end

helpers.describe("keyboard hook: tap-hold counters", function()
	helpers.it("counts one engine decision per physical event and every event written back", function()
		local snapshot = drive({ { 58, 1 }, { 30, 1 }, { 30, 0 }, { 58, 0 } }, true)
		helpers.assert_eq(snapshot.counts["taphold.processed"], 4)
		-- CapsLock+A is Ctrl down, A down, A up, Ctrl up.
		helpers.assert_eq(snapshot.counts["input.forwarded_events"], 4)
	end)

	helpers.it("counts no engine decision without an engine", function()
		local snapshot = drive({ { 30, 1 }, { 30, 0 } }, false)
		helpers.assert_eq(snapshot.counts["taphold.processed"], 0)
		helpers.assert_eq(snapshot.counts["input.forwarded_events"], 2, "a pass-through key is still forwarded")
	end)
end)

helpers.describe("keyboard hook: idle wait", function()
	helpers.it("answers nil while the hook is not running", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		helpers.assert_nil(kh.idle_wait(8), "a stopped hook cannot sleep on its sources")
	end)
end)
