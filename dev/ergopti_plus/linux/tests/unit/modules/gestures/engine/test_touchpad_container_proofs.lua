--- tests/unit/modules/gestures/engine/test_touchpad_container_proofs.lua

--- ==============================================================================
--- MODULE: Touchpad Checks Closed On A Container Proof
--- DESCRIPTION:
--- The touchpad lines of TODO-tests-linux.md "To confirm on Linux" asked for a real pad.
--- The maintainer's rule of 2026-11-10 closes a check the cloud cannot run on
--- hardware with a container proof (docs/memory/maintainer-decisions.md). Each
--- case here replays a trace in `libinput record` format, kept under
--- tests/fixtures, through the daemon's own chain: the bytes the kernel would
--- deliver, with their stamps, into the real evdev reader, the real
--- `start_reading` and pump of the gesture manager, the real decoder and the
--- real dispatch. Only the device lookup (which node, its resolution) and the
--- key emitter at the far end are scripted; the log lines are the manager's.
---
--- PROOF RECEIPTS (the TODO lines cite these case names):
--- - container-proof-gestures: a three-finger pad (no BTN_TOOL_QUADTAP) logs
---   its unreachable four- and five-finger slots and warns about a bound one;
---   a two-finger scroll with a thumb resting reports two fingers; a brisk
---   three-finger tap still reports tap_3.
--- - container-proof-incremental: a three-finger horizontal swipe steps one
---   action per 3.5 mm, a reversal steps back, a vertical one steps one tab
---   per 25 mm, the log names the pad's resolution, and a pad that reports
---   none logs it and fires once.
--- - container-proof-axis-slots: with only swipe_3_horiz bound a left and a
---   right swipe each run it once; binding swipe_3_left too makes the left
---   swipe run that one instead.
---
--- WHAT THE REPLAYS FOUND (fixed with them):
--- 1. The incremental tracker read the mode of the unbound direction slot
---    (swipe_3_left, incremental by default) while the axis slot answered, so
---    swipe_3_horiz ran about once per 3.5 mm instead of once; macOS reads the
---    answering slot's mode.
--- 2. The tracker measured travel from the first live frame, losing what the
---    fingers moved while the decoder held their count: a brisk 21 mm swipe
---    stepped five times instead of six.
--- ==============================================================================

local helpers = require("tests.helpers")

local Record = helpers.load_module("tests.support.touchpad_record")

local MANAGER, READER, FINDER = "modules.gestures.manager", "platform.input.evdev_reader", "modules.gestures.touchpad_finder"
local EMITTER, LOGGER = "modules.gestures.combo_emitter", "core.logger.engine.shim"

--- Reads and decodes a trace of tests/fixtures.
--- @param name string
--- @return table trace
local function trace_of(name)
	local file = assert(io.open(helpers.driver_root() .. "/tests/fixtures/" .. name, "rb"))
	local trace = assert(Record.decode(file:read("*a")))
	file:close()
	return trace
end

--- Replays a trace through the daemon's gesture chain.
--- @param name string The fixture.
--- @param setup table { max_fingers, units (nil: no resolution), bindings = { slot = action }, modes = { slot = mode } }
--- @return table result { gestures, pressed, lines, manager }
local function replay(name, setup)
	local trace = trace_of(name)
	local names = { MANAGER, READER, FINDER, EMITTER, LOGGER }
	local saved = {}
	for _, module_name in ipairs(names) do saved[module_name] = package.loaded[module_name] end
	local result = { gestures = {}, pressed = {}, lines = {} }
	local ok, failure = xpcall(function()
		local function record(_, fmt, ...)
			local formatted, text = pcall(string.format, fmt, ...)
			result.lines[#result.lines + 1] = formatted and text or tostring(fmt)
		end
		package.loaded[LOGGER] = {
			debug = record, trace = record, done = record, info = record, start = record, success = record,
			warn = record, error = record, set_level = function() end, set_sink = function() end,
			ring_buffer_snapshot = function() return {} end,
		}
		package.loaded[EMITTER] = {
			press = function(combo) result.pressed[#result.pressed + 1] = combo; return true end,
			can_fallback = function() return false end,
		}
		-- The device lookup: which node is the pad and what its EVIOCGABS says.
		local real_finder = helpers.load_module(FINDER)
		package.loaded[FINDER] = setmetatable({
			find = function()
				return { path = "/dev/input/event7", name = trace.name, is_touchpad = true, semi_mt = false,
					max_fingers = setup.max_fingers }
			end,
			read_resolution = function() return setup.units, setup.units end,
		}, { __index = real_finder })
		-- The kernel: the trace's events as the binary records read(2) returns.
		local reader = helpers.load_module(READER)
		local codec = require("platform.input.event")
		local pending, cursor = {}, 1
		for _, event in ipairs(trace.events) do
			pending[#pending + 1] = codec.encode(event.type, event.code, event.value, codec.native_size(), event.timestamp_us)
		end
		reader._set_backend({
			open = function(path) helpers.assert_eq(path, "/dev/input/event7"); return 7 end,
			read = function(_, count)
				local bytes = pending[cursor]
				if not bytes then return nil, "would_block" end
				helpers.assert_eq(#bytes, count); cursor = cursor + 1; return bytes
			end,
			close = function() return true end,
		})
		local manager = helpers.load_module(MANAGER)
		manager.init({ enabled = false, persist = false })
		for slot, action in pairs(setup.bindings or {}) do helpers.assert_true(manager.set_action(slot, action)) end
		for slot, mode in pairs(setup.modes or {}) do helpers.assert_true(manager.set_mode(slot, mode)) end
		local real_dispatch = manager.dispatch_gesture
		manager.dispatch_gesture = function(gesture)
			result.gestures[#result.gestures + 1] = gesture
			return real_dispatch(gesture)
		end
		helpers.assert_true(manager.start_reading(), "the pad is opened through the real reader")
		helpers.assert_true(manager.enable())
		-- One bounded batch per daemon tick, until the trace is drained.
		repeat until (manager.pump() or 0) == 0
		helpers.assert_eq(cursor - 1, #pending, "every recorded event was read")
		helpers.assert_true(manager.stop_reading())
		reader._reset_backend()
		result.manager = manager
	end, debug.traceback)
	for _, module_name in ipairs(names) do package.loaded[module_name] = saved[module_name] end
	if not ok then error(failure, 0) end
	return result
end

--- Whether a line containing every needle was logged.
local function logged(lines, ...)
	local needles = { ... }
	for _, line in ipairs(lines) do
		local all = true
		for _, needle in ipairs(needles) do if not line:find(needle, 1, true) then all = false; break end end
		if all then return true end
	end
	return false
end

--- How many times a combination was pressed.
local function count(pressed, combo)
	local n = 0
	for _, value in ipairs(pressed) do if value == combo then n = n + 1 end end
	return n
end

helpers.describe("touchpad container proofs: TODO To confirm on Linux", function()
	helpers.it("container-proof-gestures: a three-finger pad, a scroll with a thumb resting, a brisk tap_3", function()
		local result = replay("touchpad_record_three_finger_alps.yml", {
			max_fingers = 3, units = 30, bindings = { tap_3 = "enter", swipe_3_left = "tab_prev", swipe_4_up = "enter" },
			modes = { swipe_3_left = "x1" },
		})
		local got = {}
		for _, gesture in ipairs(result.gestures) do
			got[#got + 1] = string.format("%d:%s:%s", gesture.fingers, tostring(gesture.direction), tostring(gesture.tap))
		end
		helpers.assert_eq(got, { "2:down:false", "3:nil:true", "3:left:false" },
			"the resting thumb never makes the scroll a three-finger swipe")
		local manager = result.manager
		helpers.assert_eq(count(result.pressed, manager.emit_combo_for("enter")), 1, "tap_3 ran once")
		helpers.assert_eq(count(result.pressed, manager.emit_combo_for("tab_prev")), 1, "swipe_3_left ran once")
		helpers.assert_true(logged(result.lines, "counts up to 3 finger(s)", "swipe_4_up", "tap_5"),
			"the start names the slots a three-finger pad can never fire")
		helpers.assert_true(logged(result.lines, "Gesture swipe_4_up is bound", "will never fire"))
		helpers.assert_true(logged(result.lines, "AlpsPS/2 ALPS GlidePoint", "up to 3 finger(s)"))
	end)

	helpers.it("container-proof-incremental: steps per 3.5 mm, back on reversal, a tab per 25 mm, the resolution logged", function()
		local result = replay("touchpad_record_incremental_elan.yml", {
			max_fingers = 5, units = 30,
			bindings = { swipe_3_right = "word_next", swipe_3_left = "word_prev", swipe_3_down = "tab_next" },
			modes = { swipe_3_right = "incremental", swipe_3_left = "incremental", swipe_3_down = "incremental" },
		})
		local manager = result.manager
		helpers.assert_eq(manager.get_sensitivity("swipe_3_right"), 3.5)
		helpers.assert_eq(manager.get_sensitivity("swipe_3_down"), 25)
		-- 21 mm right: the first step at 3.5 mm, then one per 3.5 mm.
		helpers.assert_eq(count(result.pressed, manager.emit_combo_for("word_next")), 6)
		-- Back 10.5 mm: rebased 1.75 mm after the last fire, 8.75 mm earn two.
		helpers.assert_eq(count(result.pressed, manager.emit_combo_for("word_prev")), 2)
		-- 52 mm down: the first tab at 4 mm, the next at 29, none at 54.
		helpers.assert_eq(count(result.pressed, manager.emit_combo_for("tab_next")), 2)
		helpers.assert_true(logged(result.lines, "/dev/input/event7: 30 x 30 units per mm"))

		local flat = replay("touchpad_record_incremental_elan.yml", {
			max_fingers = 5, units = nil,
			bindings = { swipe_3_right = "word_next", swipe_3_down = "tab_next" },
			modes = { swipe_3_right = "incremental", swipe_3_down = "incremental" },
		})
		helpers.assert_true(logged(flat.lines, "/dev/input/event7 reports no resolution", "fire once"))
		helpers.assert_eq(count(flat.pressed, flat.manager.emit_combo_for("word_next")), 1, "one action per swipe")
		helpers.assert_eq(count(flat.pressed, flat.manager.emit_combo_for("tab_next")), 1)
	end)

	helpers.it("container-proof-axis-slots: swipe_3_horiz runs on both sides until swipe_3_left is bound", function()
		local axis = replay("touchpad_record_axis_swipes_elan.yml", {
			max_fingers = 5, units = 30, bindings = { swipe_3_horiz = "enter", swipe_3_left = "none", swipe_3_right = "none" },
		})
		helpers.assert_eq(#axis.gestures, 2)
		helpers.assert_eq(count(axis.pressed, axis.manager.emit_combo_for("enter")), 2, "left and right each run it once")
		local both = replay("touchpad_record_axis_swipes_elan.yml", {
			max_fingers = 5, units = 30, bindings = { swipe_3_horiz = "enter", swipe_3_left = "tab_prev", swipe_3_right = "none" },
		})
		-- swipe_3_left keeps its own default mode, incremental: 25 mm at 3.5 mm.
		helpers.assert_eq(count(both.pressed, both.manager.emit_combo_for("tab_prev")), 7, "the left swipe runs swipe_3_left")
		helpers.assert_eq(count(both.pressed, both.manager.emit_combo_for("enter")), 1,
			"the right one still runs the axis slot, once, in the axis slot's own x1 mode")
	end)
end)
