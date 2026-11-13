--- tests/unit/modules/gestures/engine/test_resting_thumb_join.lua

--- ==============================================================================
--- MODULE: Regression — a resting thumb never makes a pair three fingers
---         (resting-thumb-join)
--- DESCRIPTION:
--- Mac field report of 2026-11-05: at 20:06 a thumb resting about 60 mm from
--- two swiping fingers joined them 20 ms after their landing, and the swipe
--- fired the three-finger tab_close; at 20:04 a held tap with the same thumb
--- beside the pair committed tap_3 (a left click).
---
--- ROOT CAUSE ENCODED: the join gate accepted a third contact once it had held
--- pair_join_confirm_ms, with no spatial check, and the tap commit took any
--- three contacts. Both join paths and the three-finger tap commit now ask the
--- shared rule (_shared/gestures/engine/contact_join.lua), which refuses a contact
--- farther than MAX_FINGER_GAP_MM from the others or larger than
--- MAX_MAJOR_RATIO times the largest of them. Three fingers of one hand still
--- join and tap.
--- ==============================================================================

local helpers = require("tests.helpers")
local ContactJoin = require("gestures.engine.contact_join")

-- About 125 Hz, the rate the touch device reports frames at.
local FRAME_DT_SEC = 0.008
local STEP = 0.6

-- Two fingers of one hand, 20 mm apart, as the trackpad reports millimetres.
local INDEX  = { x = 40, y = 50, major = 8 }
local MIDDLE = { x = 60, y = 50, major = 8.5 }
local RING   = { x = 80, y = 50, major = 8.2 }
-- The field thumb: about 60 mm below the pair, fingertip-sized.
local FAR_THUMB = { x = 50, y = -10, major = 9 }
-- A thumb lying flat next to the pair: near, but twice a fingertip.
local FLAT_THUMB = { x = 50, y = 25, major = 17 }

local GESTURES = {
	swipe_2_up = "none", swipe_2_down = "none", swipe_2_left = "none", swipe_2_right = "none",
	swipe_3_up = "tab_close", swipe_3_down = "tab_close",
	swipe_3_left = "none", swipe_3_right = "none",
	tap_2 = "none", tap_3 = "left_click", tap_4 = "none", tap_5 = "none",
}





-- =================================
-- =================================
-- ======= 1/ Engine Harness =======
-- =================================
-- =================================

--- Builds a fresh engine on a driven clock and returns a frame player.
--- @return table harness { frame, lift, fired, rejection, finish }
local function new_harness()
	local hs = _G.hs
	local saved_clock = hs.timer.secondsSinceEpoch
	local saved_absolute = hs.timer.absoluteTime
	local saved_scheduler = package.loaded["core.events.timer_scheduler"]
	local saved_timings = package.loaded["infra.timings"]
	local saved_logger = package.loaded["core.logger.engine.logger"]
	local debug_lines = {}
	local real_logger = require("core.logger.engine.logger")
	package.loaded["core.logger.engine.logger"] = setmetatable({
		debug = function(module_name, fmt, ...)
			local ok, line = pcall(string.format, fmt, ...)
			debug_lines[#debug_lines + 1] = ok and line or tostring(fmt)
			return real_logger.debug(module_name, fmt, ...)
		end,
	}, { __index = real_logger })
	local clock = 1000.0
	hs.timer.secondsSinceEpoch = function() return clock end
	hs.timer.absoluteTime = function() return clock * 1e9 end
	package.loaded["core.events.timer_scheduler"] = nil
	package.loaded["infra.timings"] = nil
	package.loaded["modules.gestures.engine"] = nil
	hs.eventtap.__reset()

	local Engine = require("modules.gestures.engine")
	local fired = {}
	local initialized = Engine.init({ enabled = true, ga = GESTURES, modes = {}, sensitivities = {} }, {
		execute_single = function(a) fired[#fired + 1] = a; return true end,
		execute_axis   = function(a) fired[#fired + 1] = a; return true end,
		set_gesture_in_progress = function() end,
	})
	helpers.assert_true(initialized == true, "the engine must initialize on the stub eventtap")

	local harness = { fired = fired }

	--- Finds the first rejection line naming a gate.
	--- @param gate string Gate name as the engine logs it.
	--- @return string|nil line
	function harness.rejection(gate)
		local needle = "Three-finger candidate rejected by " .. gate .. ":"
		for _, line in ipairs(debug_lines) do
			if line:find(needle, 1, true) then return line end
		end
		return nil
	end

	--- Plays one frame; the contacts listed in `moving` travel by `dy`.
	--- @param contacts table Array of { x, y, major }.
	--- @param moving table|nil Set of travelling indices; nil means all.
	--- @param dy number Offset of the travelling contacts.
	function harness.frame(contacts, moving, dy)
		local touches = {}
		for i, c in ipairs(contacts) do
			local offset = (moving == nil or moving[i]) and dy or 0
			touches[#touches + 1] = {
				absoluteVector = { position = { x = c.x, y = c.y + offset } },
				majorAxis = c.major,
			}
		end
		Engine.process_frame(touches)
		clock = clock + FRAME_DT_SEC
	end

	--- Lifts every finger, over the frames a lift takes to confirm.
	function harness.lift()
		for _ = 1, 12 do
			Engine.process_frame({})
			clock = clock + FRAME_DT_SEC
		end
	end

	--- Restores the clock and drops the engine instance.
	function harness.finish()
		Engine.stop()
		hs.timer.secondsSinceEpoch = saved_clock
		hs.timer.absoluteTime = saved_absolute
		package.loaded["core.events.timer_scheduler"] = saved_scheduler
		package.loaded["infra.timings"] = saved_timings
		package.loaded["core.logger.engine.logger"] = saved_logger
		package.loaded["modules.gestures.engine"] = nil
	end

	return harness
end

--- Lands a pair, joins a third contact after 24 ms (past the 20 ms pair join),
--- then swipes every contact but a resting third one, and lifts.
--- @param h table Harness.
--- @param third table The joining contact.
--- @param third_moves boolean Whether the third contact travels too.
local function pair_then_third_swipe(h, third, third_moves)
	local pair = { INDEX, MIDDLE }
	for _ = 1, 3 do h.frame(pair, nil, 0) end
	local three = { INDEX, MIDDLE, third }
	local moving = nil
	if not third_moves then moving = { true, true, false } end
	for i = 0, 30 do h.frame(three, moving, i * STEP) end
	h.lift()
end

--- Holds three contacts still for a tap, then lifts.
--- @param h table Harness.
--- @param contacts table The three contacts, landing together.
local function three_finger_tap(h, contacts)
	for _ = 1, 6 do h.frame(contacts, nil, 0) end
	h.lift()
end





-- ==============================
-- ==============================
-- ======= 2/ Shared Rule =======
-- ==============================
-- ==============================

helpers.describe("resting thumb: shared third-contact rule", function()
	helpers.it("refuses a far or oversized third contact and admits a hand", function()
		helpers.assert_eq(ContactJoin.refusal({ INDEX, MIDDLE, RING }), nil)
		helpers.assert_eq((ContactJoin.refusal({ INDEX, MIDDLE, FAR_THUMB })), "far")
		helpers.assert_eq((ContactJoin.refusal({ INDEX, MIDDLE, FLAT_THUMB })), "oversized")
		-- A pair and four contacts are never judged: five-finger swipes take the thumb.
		helpers.assert_eq(ContactJoin.refusal({ INDEX, FAR_THUMB }), nil)
		helpers.assert_eq(ContactJoin.refusal({ INDEX, MIDDLE, RING, FAR_THUMB }), nil)
		-- Without a major axis on every contact only the gap is judged.
		helpers.assert_eq(ContactJoin.refusal({ INDEX, MIDDLE, { x = 50, y = 25 } }), nil)
		-- The bound sits between a spread hand and the field thumb.
		helpers.assert_true(ContactJoin.MAX_FINGER_GAP_MM >= 30 and ContactJoin.MAX_FINGER_GAP_MM < 60)
	end)
end)





-- ===========================================
-- ===========================================
-- ======= 3/ The Field Report's Cases =======
-- ===========================================
-- ===========================================

helpers.describe("resting thumb: engine join paths and tap commit", function()
	-- The field swipe passed the cohesion gate, so the thumb rolled along with
	-- the pair: only its distance tells it apart.
	helpers.it("20:06 — a far thumb joining a swiping pair does not fire tab_close", function()
		local h = new_harness()
		local ok, err = pcall(pair_then_third_swipe, h, FAR_THUMB, true)
		local fired, line = h.fired, h.rejection("finger geometry")
		h.finish()
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(#fired, 0, "the pair stays a two-finger scroll: " .. table.concat(fired, ","))
		helpers.assert_true(line ~= nil and line:find("far", 1, true) ~= nil,
			"the refusal is logged with its reason")
	end)

	helpers.it("20:04 — a held tap beside a far thumb does not commit tap_3", function()
		local h = new_harness()
		local ok, err = pcall(three_finger_tap, h, { INDEX, MIDDLE, FAR_THUMB })
		local fired, line = h.fired, h.rejection("finger geometry")
		h.finish()
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(#fired, 0, "no tap_3: " .. table.concat(fired, ","))
		helpers.assert_true(line ~= nil and line:find("tap_3", 1, true) ~= nil, "the tap refusal is logged")
	end)

	helpers.it("an oversized thumb joining near the pair is refused too, even when it travels", function()
		local h = new_harness()
		local ok, err = pcall(pair_then_third_swipe, h, FLAT_THUMB, true)
		local fired, line = h.fired, h.rejection("finger geometry")
		h.finish()
		helpers.assert_true(ok, tostring(err))
		helpers.assert_eq(#fired, 0, table.concat(fired, ","))
		helpers.assert_true(line ~= nil and line:find("oversized", 1, true) ~= nil)
	end)

	helpers.it("three fingers of one hand still join, swipe and tap", function()
		local h = new_harness()
		local ok, err = pcall(function()
			pair_then_third_swipe(h, RING, true)
		end)
		local after_swipe = #h.fired
		local ok_tap, err_tap = pcall(function()
			for _ = 1, 4 do h.lift() end
			three_finger_tap(h, { INDEX, MIDDLE, RING })
		end)
		local fired = h.fired
		h.finish()
		helpers.assert_true(ok, tostring(err))
		helpers.assert_true(ok_tap, tostring(err_tap))
		helpers.assert_true(after_swipe >= 1 and fired[1] == "tab_close", "the swipe fires: " .. table.concat(fired, ","))
		helpers.assert_eq(fired[#fired], "left_click", "the tap fires: " .. table.concat(fired, ","))
	end)
end)
