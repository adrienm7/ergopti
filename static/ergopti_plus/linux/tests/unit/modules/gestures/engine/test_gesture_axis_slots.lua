--- tests/unit/modules/gestures/engine/test_gesture_axis_slots.lua

--- ==============================================================================
--- MODULE: Horizontal Axis Slots Fire From the Touchpad
--- DESCRIPTION:
--- The shared slot space declares swipe_3_horiz, swipe_4_horiz and
--- swipe_5_horiz for Linux, and the Gestures menu offers them. The recognizer
--- only ever names a direction, so a binding on an axis slot was accepted,
--- saved and never fired (LIN-009 / LG-001). The axis slot is now the binding
--- of both horizontal directions of its finger count, used when the direction
--- slot itself is unbound.
---
--- WHY SYNTHETIC EVDEV FRAMES:
--- The defect sat between two correct halves: a decoder that names "right" and
--- a dispatcher that looks up "swipe_3_right". Only a test that starts from the
--- frames the kernel sends and ends at the emitted key can see that join. The
--- emitter is replaced at its press boundary, so no key reaches the session.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")
local Decoder = helpers.load_module("modules.gestures.mt_decoder")

local BTN_TOUCH = 0x14a
local TOOL = { [1] = 0x145, [2] = 0x14d, [3] = 0x14e, [4] = 0x14f, [5] = 0x148 }
local EMITTER = "modules.gestures.combo_emitter"
local MANAGER = "modules.gestures.manager"
local READER = "adapters.evdev_reader"

--- The evdev events of one whole gesture, landing, moving and lifting.
--- @param fingers integer Contacts reported through BTN_TOOL_*.
--- @param dx integer Total horizontal travel in device units.
--- @param dy integer Total vertical travel in device units, positive downward.
--- @return table events
local function gesture_events(fingers, dx, dy)
	local events = {}
	local function push(t, c, v) events[#events + 1] = { type = t, code = c, value = v } end
	local base_x, base_y = 1000, 900

	for index = 0, fingers - 1 do
		push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_TRACKING_ID, 700 + index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200)
		push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y)
		if index > 0 then push(Decoder.EV_KEY, TOOL[index], 0) end
		push(Decoder.EV_KEY, TOOL[index + 1], 1)
		if index == 0 then push(Decoder.EV_KEY, BTN_TOUCH, 1) end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end

	for step = 1, 4 do
		for index = 0, fingers - 1 do
			push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
			push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200 + math.floor(dx * step / 4))
			push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y + math.floor(dy * step / 4))
		end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end

	for index = fingers - 1, 0, -1 do
		push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
		push(Decoder.EV_ABS, Decoder.ABS_MT_TRACKING_ID, -1)
		push(Decoder.EV_KEY, TOOL[index + 1], 0)
		if index > 0 then push(Decoder.EV_KEY, TOOL[index], 1) end
		push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	end
	push(Decoder.EV_KEY, BTN_TOUCH, 0)
	push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0)
	return events
end

--- Runs `body` against a fresh manager whose combo emitter only records.
--- @param bindings table slot -> action, applied before reading starts.
--- @param events table|nil evdev events the fake reader delivers.
--- @param body function body(manager, pressed)
local function with_manager(bindings, events, body)
	local saved = {
		[EMITTER] = package.loaded[EMITTER],
		[MANAGER] = package.loaded[MANAGER],
		[READER] = package.loaded[READER],
	}
	local ok, failure = xpcall(function()
		local pressed = {}
		package.loaded[EMITTER] = {
			press = function(combo)
				pressed[#pressed + 1] = combo
				return true
			end,
			can_fallback = function() return false end,
		}
		local reader = Fakes.evdev_reader({ events = events or {} })
		package.loaded[READER] = reader
		local M = helpers.load_module(MANAGER)
		M.init({ enabled = false, persist = false })
		for slot, action in pairs(bindings) do
			helpers.assert_true(M.set_action(slot, action), "the Linux catalogue must accept " .. action .. " on " .. slot)
		end
		reader.open("/dev/input/event-fake", reader.TOUCHPAD)
		M._test_begin_reading(Decoder.new())
		helpers.assert_true(M.enable(), "a live reader must enable dispatch")
		body(M, pressed)
	end, debug.traceback)
	-- By name: a module that was not loaded is a nil value pairs() never visits.
	for _, name in ipairs({ EMITTER, MANAGER, READER }) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
end

--- Pumps one gesture and returns the combos it emitted.
--- @param bindings table slot -> action.
--- @param fingers integer
--- @param dx integer
--- @param dy integer
--- @return table pressed, table manager
local function pump(bindings, fingers, dx, dy)
	local pressed_out, manager_out
	with_manager(bindings, gesture_events(fingers, dx, dy), function(M, pressed)
		M.pump()
		pressed_out, manager_out = pressed, M
	end)
	return pressed_out, manager_out
end




-- =================================================================
-- =================================================================
-- ======= 1/ An axis binding fires from real frames ===============
-- =================================================================
-- =================================================================

helpers.describe("gesture axis slots: reachable from the touchpad", function()

	helpers.it("fires each horizontal axis slot from a right and a left swipe", function()
		for fingers = 3, 5 do
			local slot = "swipe_" .. fingers .. "_horiz"
			for _, dx in ipairs({ 600, -600 }) do
				local pressed, M = pump({ [slot] = "tab_next" }, fingers, dx, 0)
				helpers.assert_eq(#pressed, 1, string.format(
					"%s is the binding of both horizontal directions: a %d-finger swipe of dx=%d must run it once",
					slot, fingers, dx))
				helpers.assert_eq(pressed[1], M.emit_combo_for("tab_next"), "the axis slot's own action runs")
			end
		end
	end)

	helpers.it("lets an explicit direction slot win over the axis slot", function()
		local bindings = { swipe_3_left = "tab_prev", swipe_3_horiz = "tab_next" }
		local left, M = pump(bindings, 3, -600, 0)
		helpers.assert_eq(#left, 1, "one action per gesture, never both")
		helpers.assert_eq(left[1], M.emit_combo_for("tab_prev"),
			"a bound swipe_3_left is the user's explicit choice and must not be overridden")
		local right = pump(bindings, 3, 600, 0)
		helpers.assert_eq(#right, 1)
		helpers.assert_eq(right[1], M.emit_combo_for("tab_next"),
			"the unbound right direction falls back to the axis slot")
	end)

	helpers.it("keeps vertical and tap gestures off the horizontal axis", function()
		local bindings = { swipe_3_horiz = "tab_next" }
		helpers.assert_eq(#pump(bindings, 3, 0, -600), 0, "a vertical swipe is not on the horizontal axis")
		helpers.assert_eq(#pump(bindings, 3, 0, 0), 0, "a tap is not a swipe")
	end)

	-- Decided by the maintainer on 2026-11-11: an unbound diagonal runs its
	-- dominant straight slot, and that slot's own fallback; a bound one wins.
	helpers.it("runs an unbound diagonal's dominant direction, a bound diagonal its own (diagonal-unbound-fallback)", function()
		local axis_only = pump({ swipe_3_horiz = "tab_next" }, 3, 600, -400)
		helpers.assert_eq(#axis_only, 1, "a mostly horizontal diagonal reaches the horizontal axis slot")
		local vertical_only = pump({ swipe_3_horiz = "tab_next" }, 3, 400, -600)
		helpers.assert_eq(#vertical_only, 0, "a mostly vertical one has no horizontal slot to fall back to")
		local bound, M = pump({ swipe_3_right_up = "tab_prev", swipe_3_right = "tab_next" }, 3, 600, -400)
		helpers.assert_eq(bound, { M.emit_combo_for("tab_prev") }, "a bound diagonal keeps its own slot")
	end)

	helpers.it("gives two fingers no axis slot", function()
		local pressed = pump({ swipe_3_horiz = "tab_next" }, 2, 600, 0)
		helpers.assert_eq(#pressed, 0, "the shared slot space declares no swipe_2_horiz")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ Every advertised slot has a route ====================
-- =================================================================
-- =================================================================

--- The completed gesture that must reach a slot.
--- @param slot string
--- @return table gesture { fingers, direction, tap }
local function gesture_for(slot)
	local tap_fingers = slot:match("^tap_(%d)$")
	if tap_fingers then return { fingers = tonumber(tap_fingers), tap = true } end
	local fingers, direction = slot:match("^swipe_(%d)_(.+)$")
	assert(fingers, "unexpected gesture slot " .. slot)
	if direction == "horiz" then direction = "right" end
	return { fingers = tonumber(fingers), direction = direction, tap = false }
end

helpers.describe("gesture axis slots: no advertised slot is unreachable", function()

	helpers.it("dispatches every slot the manager offers when only it is bound", function()
		local slots
		with_manager({}, nil, function(M) slots = require("core.text.engine.table_util").sorted_keys(M.DEFAULT_GESTURES) end)
		helpers.assert_true(#slots > 0, "the manager offers gesture slots")
		local axis = 0
		for _, slot in ipairs(slots) do
			if slot:match("_horiz$") then axis = axis + 1 end
			with_manager({ [slot] = "tab_next" }, nil, function(M, pressed)
				helpers.assert_true(M.dispatch_gesture(gesture_for(slot)),
					slot .. " is offered on Linux, so a gesture must be able to fire it")
				helpers.assert_eq(#pressed, 1, slot .. " runs its action once")
			end)
		end
		helpers.assert_eq(axis, 3, "the three shared axis slots are part of the offered set")
	end)

end)
