--- tests/unit/modules/gestures/engine/test_gesture_axis_slots.lua

--- ==============================================================================
--- MODULE: Regression — the horizontal axis gesture slots fire on macOS
--- DESCRIPTION:
--- swipe_3_horiz, swipe_4_horiz and swipe_5_horiz were offered and persisted
--- but the engine resolved only direction slots, so a binding on them never
--- fired. The engine now follows the rule Linux adopted on 2026-11-06
--- (docs/memory/maintainer-decisions.md): an explicit direction slot wins; the
--- axis slot runs only for an unbound straight left or right swipe; the sign
--- comes from the travel. Vertical swipes have no axis slot on any OS.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Asserts equality in the (expected, actual) order used below.
local function eq(expected, actual, message) helpers.assert_eq(actual, expected, message) end

local FRAME_DT_SEC = 0.008

--- Plays one horizontal or vertical swipe of a hand and returns what fired.
--- @param ga table Slot bindings merged over an all-none table.
--- @param fingers number Finger count of the hand.
--- @param dx number Horizontal travel of the swipe.
--- @param dy number Vertical travel of the swipe.
--- @return table fired Array of { action, slot|sign }.
local function play(ga, fingers, dx, dy)
	local hs = _G.hs
	local saved_clock, saved_absolute = hs.timer.secondsSinceEpoch, hs.timer.absoluteTime
	local saved_scheduler = package.loaded["adapters.timer_scheduler"]
	local saved_timings = package.loaded["infra.timings"]
	local clock = 3000.0
	hs.timer.secondsSinceEpoch = function() return clock end
	hs.timer.absoluteTime = function() return clock * 1e9 end
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["modules.gestures.engine"] = nil
	hs.eventtap.__reset()

	local Engine = require("modules.gestures.engine")
	local fired = {}
	local bindings = {}
	for _, n in ipairs({ 2, 3, 4, 5 }) do
		bindings["tap_" .. n] = "none"
		for _, d in ipairs({ "left", "right", "up", "down", "left_up", "right_up", "left_down", "right_down" }) do
			bindings["swipe_" .. n .. "_" .. d] = "none"
		end
	end
	for slot, action in pairs(ga) do bindings[slot] = action end
	helpers.assert_true(Engine.init({
		enabled = true, ga = bindings, modes = {}, sensitivities = {},
		system_held = function() return false end,
	}, {
		execute_single = function(action, slot) fired[#fired + 1] = { action, slot }; return true end,
		execute_axis   = function(action, forward) fired[#fired + 1] = { action, forward }; return true end,
		set_gesture_in_progress = function() end,
	}) == true, "the engine must initialize on the stub eventtap")

	local function frame(ox, oy)
		local touches = {}
		for i = 1, fingers do
			touches[i] = { absoluteVector = { position = { x = 30 + i * 8 + ox, y = 50 + oy } } }
		end
		Engine.process_frame(touches)
		clock = clock + FRAME_DT_SEC
	end
	for _ = 1, 10 do frame(0, 0) end
	-- Few, large steps: a slow diagonal would lock its first small move to the
	-- dominant axis, which is the engine's existing behaviour for every slot.
	local steps = 8
	for i = 1, steps do frame(dx * i / steps, dy * i / steps) end
	Engine.process_frame({})
	Engine.stop()
	hs.timer.secondsSinceEpoch, hs.timer.absoluteTime = saved_clock, saved_absolute
	package.loaded["adapters.timer_scheduler"] = saved_scheduler
	package.loaded["infra.timings"] = saved_timings
	package.loaded["modules.gestures.engine"] = nil
	return fired
end

helpers.describe("gestures.engine: horizontal axis slots", function()

	helpers.it("an unbound right swipe runs the axis slot", function()
		local fired = play({ swipe_3_horiz = "word_next" }, 3, 20, 0)
		eq(1, #fired, "the axis action must fire exactly once")
		eq("word_next", fired[1][1])
		eq("swipe_3_horiz", fired[1][2])
	end)

	helpers.it("an unbound left swipe runs the axis slot too, for every finger count", function()
		for _, n in ipairs({ 3, 4, 5 }) do
			local fired = play({ ["swipe_" .. n .. "_horiz"] = "word_prev" }, n, -20, 0)
			eq(1, #fired, n .. " fingers must fire once")
			eq("swipe_" .. n .. "_horiz", fired[1][2])
		end
	end)

	helpers.it("a bound direction slot wins and the axis slot stays silent", function()
		local fired = play({ swipe_3_right = "tab_next", swipe_3_horiz = "word_next" }, 3, 20, 0)
		eq(1, #fired, "one gesture must never run two actions")
		eq("tab_next", fired[1][1])
		eq("swipe_3_right", fired[1][2])
	end)

	helpers.it("the axis slot answers only the unbound direction", function()
		local ga = { swipe_3_right = "tab_next", swipe_3_horiz = "word_prev" }
		local fired = play(ga, 3, -20, 0)
		eq("word_prev", fired[1] and fired[1][1], "left is unbound: the axis slot answers")
	end)

	helpers.it("vertical swipes and other finger counts do not run an axis slot", function()
		eq(0, #play({ swipe_3_horiz = "word_next" }, 3, 0, 20), "vertical")
		eq(0, #play({ swipe_3_horiz = "word_next" }, 4, 20, 0), "4 fingers")
		eq(0, #play({ swipe_3_horiz = "word_next" }, 3, 20, 20), "diagonal")
	end)

	helpers.it("nothing fires when neither slot is bound", function()
		eq(0, #play({}, 3, 20, 0))
	end)

end)
