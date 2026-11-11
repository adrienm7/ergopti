--- tests/unit/modules/gestures/engine/test_diagonal_reversal.lua

--- ==============================================================================
--- MODULE: Diagonal Gesture Travel and Reversal Regression Test
--- DESCRIPTION:
--- An incremental diagonal counts its travel along its own 45 degree axis and
--- detects a reversal on that axis. The reversal detector once read only the Y
--- delta of a diagonal; later both the travel and the reversal were signed by
--- dx + dy, which is about zero along the right_up / left_down axis: a
--- right_up swipe with a hundredth of a millimetre of jitter saw « reversals »
--- while the fingers kept moving forward and fired 7 actions where right_down
--- fired 12 (GSS-001). Both now project on the slot's axis through the shared
--- gestures.direction module, as the Linux tracker does. These cases drive the
--- real engine frame by frame (diagonal-axis-travel).
--- ==============================================================================

local helpers = require("tests.helpers")

local FRAME_DT_SEC = 0.008
local STEP_MM = 3.5
local HAND = { { x = 40, y = 50 }, { x = 50, y = 50 }, { x = 60, y = 50 } }
local DIRECTIONS = { "up", "down", "left", "right", "left_up", "left_down", "right_up", "right_down", "horiz" }

--- Runs one three-finger path through a fresh engine.
--- @param path table { { dx, dy } } offsets of the hand from its landing point.
--- @param bindings table Slot -> action, each one incremental.
--- @return table fired Actions in order.
local function run(path, bindings)
	local hs = _G.hs
	local saved_clock, saved_absolute = hs.timer.secondsSinceEpoch, hs.timer.absoluteTime
	local saved_scheduler, saved_timings = package.loaded["adapters.timer_scheduler"], package.loaded["infra.timings"]
	local clock = 2000.0
	hs.timer.secondsSinceEpoch = function() return clock end
	hs.timer.absoluteTime = function() return clock * 1e9 end
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["modules.gestures.engine"] = nil
	hs.eventtap.__reset()
	local ga = { tap_2 = "none", tap_3 = "none", tap_4 = "none", tap_5 = "none" }
	for fingers = 2, 5 do
		for _, direction in ipairs(DIRECTIONS) do ga["swipe_" .. fingers .. "_" .. direction] = "none" end
	end
	local modes, sensitivities = {}, {}
	for slot, action in pairs(bindings) do
		ga[slot], modes[slot], sensitivities[slot] = action, "incremental", STEP_MM
	end
	local Engine = require("modules.gestures.engine")
	local fired = {}
	local ok, err = xpcall(function()
		assert(Engine.init({ enabled = true, ga = ga, modes = modes, sensitivities = sensitivities }, {
			execute_single = function(action) fired[#fired + 1] = action; return true end,
			execute_axis = function(action) fired[#fired + 1] = action; return true end,
			set_gesture_in_progress = function() end,
		}))
		local function frame(dx, dy)
			local touches = {}
			for _, contact in ipairs(HAND) do
				touches[#touches + 1] = { absoluteVector = { position = { x = contact.x + dx, y = contact.y + dy } } }
			end
			Engine.process_frame(touches)
			clock = clock + FRAME_DT_SEC
		end
		for _ = 1, 10 do frame(0, 0) end
		for _, offset in ipairs(path) do frame(offset[1], offset[2]) end
		Engine.process_frame({})
	end, debug.traceback)
	pcall(function() require("modules.gestures.engine").stop() end)
	hs.timer.secondsSinceEpoch, hs.timer.absoluteTime = saved_clock, saved_absolute
	package.loaded["adapters.timer_scheduler"], package.loaded["infra.timings"] = saved_scheduler, saved_timings
	package.loaded["modules.gestures.engine"] = nil
	if not ok then error(err, 0) end
	return fired
end

--- A straight 45 degree path of 20 frames, 1.5 mm per axis each, with a
--- hundredth-of-a-millimetre alternating jitter across it.
--- @param sx number Horizontal sense (1 right, -1 left).
--- @param sy number Vertical sense (1 down, -1 up).
--- @return table path
local function diagonal(sx, sy)
	local path = {}
	for i = 1, 20 do path[#path + 1] = { sx * 1.5 * i, sy * 1.5 * i + ((i % 2 == 0) and 0.02 or -0.02) } end
	return path
end

local function count(fired, action)
	local n = 0
	for _, value in ipairs(fired) do if value == action then n = n + 1 end end
	return n
end

helpers.describe("gestures/engine.lua: diagonal travel and reversal (diagonal-axis-travel)", function()
	helpers.it("counts right_up as far as right_down: no false reversal (diagonal-axis-travel)", function()
		local down = count(run(diagonal(1, 1), { swipe_3_right_down = "app_expose" }), "app_expose")
		local up = count(run(diagonal(1, -1), { swipe_3_right_up = "app_expose" }), "app_expose")
		helpers.assert_true(down >= 10, "the right_down control earns its steps (" .. down .. ")")
		helpers.assert_eq(up, down, "right_up travels the same distance and earns the same steps")
		local left_down = count(run(diagonal(-1, 1), { swipe_3_left_down = "app_expose" }), "app_expose")
		helpers.assert_eq(left_down, down, "and so does left_down, on the same axis")
	end)

	helpers.it("still reverses a right_up swipe that comes back (diagonal-axis-travel)", function()
		local path = diagonal(1, -1)
		for i = 19, 0, -1 do path[#path + 1] = { 1.5 * i, -1.5 * i } end
		local fired = run(path, { swipe_3_right_up = "tab_next", swipe_3_left_down = "tab_prev" })
		helpers.assert_true(count(fired, "tab_next") >= 10, "forward steps")
		helpers.assert_true(count(fired, "tab_prev") >= 1, "the way back is a reversal onto left_down")
		helpers.assert_eq(fired[1], "tab_next", "forward first")
	end)

	-- A slow diagonal locked on the dominant straight axis its first small move
	-- named, then dropped the whole swipe at commit as « not the locked
	-- direction » (GSM-001, diagonal-decided-axis).
	helpers.it("locks a slow diagonal on its diagonal (diagonal-decided-axis)", function()
		local path = {}
		for i = 1, 20 do path[#path + 1] = { 0.8 * i, -0.8 * i + ((i % 2 == 0) and 0.05 or -0.05) } end
		local fired = run(path, { swipe_3_right_up = "app_expose" })
		helpers.assert_true(count(fired, "app_expose") >= 4, "the right_up slot steps (" .. #fired .. ")")
		fired = run(path, { swipe_3_right_up = "app_expose", swipe_3_up = "tab_prev", swipe_3_right = "tab_next" })
		helpers.assert_eq(count(fired, "tab_prev") + count(fired, "tab_next"), 0, "never a straight slot")
	end)

	-- Decided by the maintainer on 2026-11-11 (reverses part of the GSM-001
	-- change): a drifting diagonal whose slot is unbound runs its dominant
	-- straight slot; a bound diagonal still wins inside the diagonal band.
	helpers.it("runs the dominant straight slot of a drifting diagonal left unbound (diagonal-unbound-fallback)", function()
		local drift = {}
		for i = 1, 20 do drift[#drift + 1] = { 1.0 * i, -0.5 * i } end
		local fired = run(drift, { swipe_3_right = "tab_next" })
		helpers.assert_true(count(fired, "tab_next") >= 4, "the straight right slot steps (" .. #fired .. ")")
		fired = run(drift, { swipe_3_right_up = "app_expose", swipe_3_right = "tab_next" })
		helpers.assert_true(count(fired, "app_expose") >= 4, "a bound right_up keeps the drift")
		helpers.assert_eq(count(fired, "tab_next"), 0, "and the straight slot never fires beside it")
	end)
end)

return true
