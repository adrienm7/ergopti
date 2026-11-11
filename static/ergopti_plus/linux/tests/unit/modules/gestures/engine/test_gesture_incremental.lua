--- tests/unit/modules/gestures/engine/test_gesture_incremental.lua

--- ==============================================================================
--- MODULE: Incremental Swipes Step While the Fingers Move (Linux)
--- DESCRIPTION:
--- The Linux manager acted once per completed swipe, so a slot set to
--- "incremental" on macOS (one action per step of travel: words, spaces, tabs)
--- fired a single action here. It now steps while the fingers move, counting
--- millimetres through the touchpad's resolution and the shared step rule, and
--- a reversal from the last fire starts the opposite direction afresh.
---
--- WHY SYNTHETIC EVDEV FRAMES:
--- The steps come from the join of the decoder's live travel, the tracker and
--- the dispatcher; only frames in and emitted combos out see that join. The
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

-- Device units per millimetre of the fake pad.
local UNITS = 10

--- The evdev events of a three-finger touch following a path of offsets.
--- @param path table Offsets in millimetres from the landing point, one frame
---   each: an x offset, or { x, y } for a path that moves vertically too.
--- @return table events
local function touch_events(path)
	local events = {}
	local function push(t, c, v) events[#events + 1] = { type = t, code = c, value = v } end
	local fingers, base_x, base_y = 3, 1000, 900
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
	-- The count must hold for the decoder's stable frames before it is the peak.
	for _ = 1, 4 do push(Decoder.EV_SYN, Decoder.SYN_REPORT, 0) end
	for _, offset in ipairs(path) do
		local ox, oy = offset, nil
		if type(offset) == "table" then ox, oy = offset[1], offset[2] end
		for index = 0, fingers - 1 do
			push(Decoder.EV_ABS, Decoder.ABS_MT_SLOT, index)
			push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_X, base_x + index * 200 + math.floor(ox * UNITS))
			if oy then push(Decoder.EV_ABS, Decoder.ABS_MT_POSITION_Y, base_y + math.floor(oy * UNITS)) end
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

--- A path from 0 to `to` millimetres in steps of 0.5 mm, then back to `back`.
local function path(to, back)
	local points, x = {}, 0
	local step = to >= 0 and 0.5 or -0.5
	while math.abs(x) < math.abs(to) do x = x + step; points[#points + 1] = x end
	if back then
		step = back >= x and 0.5 or -0.5
		while (step > 0 and x < back) or (step < 0 and x > back) do x = x + step; points[#points + 1] = x end
	end
	return points
end

--- Pumps one touch through a fresh manager and returns the combos it pressed.
--- @param bindings table slot -> action.
--- @param modes table slot -> mode.
--- @param events table evdev events.
--- @param units number|nil Pad resolution; nil for a pad that reports none.
--- @return table pressed, table manager
local function pump(bindings, modes, events, units)
	local saved = { [EMITTER] = package.loaded[EMITTER], [MANAGER] = package.loaded[MANAGER], [READER] = package.loaded[READER] }
	local pressed, manager = {}, nil
	local ok, failure = xpcall(function()
		package.loaded[EMITTER] = {
			press = function(combo) pressed[#pressed + 1] = combo; return true end,
			can_fallback = function() return false end,
		}
		local reader = Fakes.evdev_reader({ events = events })
		package.loaded[READER] = reader
		manager = helpers.load_module(MANAGER)
		manager.init({ enabled = false, persist = false })
		for slot, action in pairs(bindings) do helpers.assert_true(manager.set_action(slot, action)) end
		for slot, mode in pairs(modes) do helpers.assert_true(manager.set_mode(slot, mode)) end
		reader.open("/dev/input/event-fake", reader.TOUCHPAD)
		manager._test_begin_reading(Decoder.new(), units, units)
		helpers.assert_true(manager.enable())
		manager.pump()
	end, debug.traceback)
	for _, name in ipairs({ EMITTER, MANAGER, READER }) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
	return pressed, manager
end

local function count(pressed, combo)
	local n = 0
	for _, value in ipairs(pressed) do if value == combo then n = n + 1 end end
	return n
end

helpers.describe("linux incremental swipes (linux-incremental-gestures)", function()
	helpers.it("incremental: a 40 mm swipe at a 3.5 mm step fires eleven actions while moving", function()
		local pressed, M = pump({ swipe_3_left = "tab_prev" }, { swipe_3_left = "incremental" },
			touch_events(path(-40)), UNITS)
		helpers.assert_eq(M.get_sensitivity("swipe_3_left"), 3.5, "the shared manifest's step")
		-- The shared rule: the first action after min(4, 3.5) mm, one more per 3.5 mm.
		helpers.assert_eq(count(pressed, M.emit_combo_for("tab_prev")), 11)
		helpers.assert_eq(#pressed, 11, "the completed swipe fires nothing more once it stepped")
	end)

	helpers.it("incremental: x1 keeps one action for the same swipe", function()
		local pressed, M = pump({ swipe_3_left = "tab_prev" }, { swipe_3_left = "x1" }, touch_events(path(-40)), UNITS)
		helpers.assert_eq(count(pressed, M.emit_combo_for("tab_prev")), 1)
		helpers.assert_eq(#pressed, 1)
	end)

	helpers.it("incremental: coming back from the last fire starts the opposite direction", function()
		local pressed, M = pump({ swipe_3_left = "tab_prev", swipe_3_right = "tab_next" },
			{ swipe_3_left = "incremental", swipe_3_right = "incremental" }, touch_events(path(-20, 0)), UNITS)
		helpers.assert_eq(count(pressed, M.emit_combo_for("tab_prev")), 5, "20 mm left: five steps")
		-- The last left fire was at -17.5 mm; coming back half a first step
		-- (1.75 mm) from there rebases at -15.5, and the 15.5 mm back to the
		-- landing point earn four steps right. Measured from -20 instead, the
		-- drift before lift-off would count as a reversal.
		helpers.assert_eq(count(pressed, M.emit_combo_for("tab_next")), 4, "15.5 mm right after the reversal: four steps")
	end)

	-- A diagonal is counted along its own axis. Signed by dx + dy, the
	-- right_up / left_down axis was noise: a jitter of a tenth of a millimetre
	-- across the swipe read as reversals while the fingers kept moving forward
	-- (GSS-001, diagonal-axis-travel).
	helpers.it("incremental: right_up earns the steps right_down earns (diagonal-axis-travel)", function()
		local function diagonal(sy)
			local points = {}
			for i = 1, 20 do points[#points + 1] = { 1.5 * i, sy * 1.5 * i + ((i % 2 == 0) and 0.1 or -0.1) } end
			return points
		end
		local down, M = pump({ swipe_3_right_down = "tab_next" }, { swipe_3_right_down = "incremental" },
			touch_events(diagonal(1)), UNITS)
		local steps = count(down, M.emit_combo_for("tab_next"))
		helpers.assert_true(steps >= 8, "the right_down control steps (" .. steps .. ")")
		local up = pump({ swipe_3_right_up = "tab_next" }, { swipe_3_right_up = "incremental" },
			touch_events(diagonal(-1)), UNITS)
		helpers.assert_eq(count(up, M.emit_combo_for("tab_next")), steps, "right_up: the same travel, the same steps")
	end)

	helpers.it("incremental: the sensitivity sets the step, within the shared range", function()
		local saved = package.loaded[MANAGER]
		local M = helpers.load_module(MANAGER)
		M.init({ enabled = false, persist = false })
		helpers.assert_true(M.set_sensitivity("swipe_3_left", 10))
		helpers.assert_eq(M.get_sensitivity("swipe_3_left"), 10)
		helpers.assert_eq(M.set_sensitivity("swipe_3_left", 0.2), false, "below the shared range")
		helpers.assert_eq(M.set_mode("swipe_3_left", "fast"), false, "an unknown mode")
		helpers.assert_eq(M.set_mode("tap_3", "incremental"), false, "a tap has no mode")
		package.loaded[MANAGER] = saved
	end)

	helpers.it("incremental: modes and steps are read from and written to config.toml", function()
		local saved = package.loaded[MANAGER]
		local tmp = os.tmpname()
		local fh = assert(io.open(tmp, "w"))
		fh:write("[gestures.modes]\nswipe_3_left = \"x1\"\nswipe_3_up = \"fast\"\n\n[gestures.sensitivities]\nswipe_3_up = 12.0\n")
		fh:close()
		local ok, failure = pcall(function()
			local M = helpers.load_module(MANAGER)
			M.init({ persist = true, config_path = tmp })
			helpers.assert_eq(M.get_mode("swipe_3_left"), "x1", "the saved mode")
			helpers.assert_eq(M.get_mode("swipe_3_up"), M.DEFAULT_MODES.swipe_3_up, "an invalid mode is left out")
			helpers.assert_eq(M.get_sensitivity("swipe_3_up"), 12, "the saved step")
			helpers.assert_true(M.set_mode("swipe_3_right", "x1"))
			helpers.assert_true(M.set_sensitivity("swipe_3_right", 7))
			local reread = helpers.load_module(MANAGER)
			reread.init({ persist = true, config_path = tmp })
			helpers.assert_eq({ reread.get_mode("swipe_3_right"), reread.get_sensitivity("swipe_3_right") }, { "x1", 7 })
		end)
		os.remove(tmp)
		package.loaded[MANAGER] = saved
		if not ok then error(failure, 0) end
	end)

	helpers.it("incremental: a pad without a resolution fires once, as x1", function()
		local pressed, M = pump({ swipe_3_left = "tab_prev" }, { swipe_3_left = "incremental" }, touch_events(path(-40)), nil)
		helpers.assert_eq(count(pressed, M.emit_combo_for("tab_prev")), 1)
	end)
end)
