--- tests/unit/modules/gestures/engine/test_mt_register_resync.lua

--- ==============================================================================
--- MODULE: Regression — multitouch registers re-read at open and after SYN_DROPPED
--- DESCRIPTION:
--- The kernel keeps each slot's axis values and the selected slot, and drops a
--- value equal to the one it holds. The decoder threw its copy away on
--- SYN_DROPPED and never had one at open, so a contact landing on a retained
--- coordinate arrived without it and the gesture never fired (deep parity audit
--- 2026-11-04, linux-gestures « Lost queue »: « native state-requery behavior
--- not established »). The reader now answers EVIOCGABS and EVIOCGMTSLOTS, and
--- the manager seeds the decoder at open and once a dropped packet ends.
---
--- The kernel here is a model of the input core's filter (a value equal to the
--- held one is dropped, ABS_MT_SLOT is sent only when the slot changes, an empty
--- frame is never delivered) and of evdev's overflow (unread events replaced by
--- SYN_DROPPED). The reader, the manager and the decoder are the real ones.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
local SYN_REPORT, SYN_DROPPED = 0, 3
local ABS_MT_SLOT, ABS_MT_TOUCH_MAJOR = 0x2f, 0x30
local ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x35, 0x36, 0x39
local BTN_TOUCH, BTN_TOOL_TRIPLETAP = 0x14a, 0x14e
local SLOT_COUNT = 5

local MANAGER, READER, FINDER = "modules.gestures.manager", "platform.input.evdev_reader", "modules.gestures.touchpad_finder"
local EMITTER, LOGGER = "modules.gestures.combo_emitter", "core.logger.engine.shim"
local DECODER = "modules.gestures.mt_decoder"




-- =========================================
-- =========================================
-- ======= 1/ The kernel model =============
-- =========================================
-- =========================================

--- A touchpad as the input core and evdev present it to one reader.
--- @return table kernel
local function new_kernel()
	local kernel = { slot = 0, reported_slot = 0, axes = {}, keys = {}, unread = {}, frame = {}, clock_us = 1000000,
		answers_registers = true }
	for index = 0, SLOT_COUNT - 1 do
		kernel.axes[index] = { [ABS_MT_TRACKING_ID] = -1, [ABS_MT_POSITION_X] = 0, [ABS_MT_POSITION_Y] = 0,
			[ABS_MT_TOUCH_MAJOR] = 0 }
	end

	local function queue(etype, code, value)
		kernel.frame[#kernel.frame + 1] = { etype, code, value }
	end

	--- One axis value of one slot, through the input core's filter.
	function kernel.abs(slot, code, value)
		if kernel.axes[slot][code] == value then return end
		kernel.axes[slot][code] = value
		if slot ~= kernel.reported_slot then
			queue(EV_ABS, ABS_MT_SLOT, slot)
			kernel.reported_slot = slot
		end
		kernel.slot = slot
		queue(EV_ABS, code, value)
	end

	function kernel.key(code, value)
		if (kernel.keys[code] or 0) == value then return end
		kernel.keys[code] = value
		queue(EV_KEY, code, value)
	end

	--- Ends a frame: delivered only when something changed.
	function kernel.syn()
		kernel.clock_us = kernel.clock_us + 10000
		if #kernel.frame == 0 then return end
		for _, event in ipairs(kernel.frame) do
			kernel.unread[#kernel.unread + 1] = { event[1], event[2], event[3], kernel.clock_us }
		end
		kernel.unread[#kernel.unread + 1] = { EV_SYN, SYN_REPORT, 0, kernel.clock_us }
		kernel.frame = {}
	end

	--- The reader fell behind while this frame was written: evdev replaces what
	--- it has not read, and the frame so far, with SYN_DROPPED; the rest of the
	--- frame follows it.
	function kernel.overflow()
		kernel.unread = { { EV_SYN, SYN_DROPPED, 0, kernel.clock_us } }
		kernel.frame = {}
	end

	--- Three fingers land on slots 0 to 2 at (x, y), (x + 200, y), (x + 400, y).
	--- @param order table|nil Slot order the hardware reports them in.
	function kernel.land(first_id, x, y, order)
		for _, slot in ipairs(order or { 0, 1, 2 }) do
			kernel.abs(slot, ABS_MT_TRACKING_ID, first_id + slot)
			kernel.abs(slot, ABS_MT_POSITION_X, x + slot * 200)
			kernel.abs(slot, ABS_MT_POSITION_Y, y)
		end
		kernel.key(BTN_TOUCH, 1); kernel.key(BTN_TOOL_TRIPLETAP, 1)
		kernel.syn()
	end

	--- The three fingers travel together by (dx, dy) per frame.
	function kernel.move(steps, dx, dy)
		for _ = 1, steps do
			for slot = 0, 2 do
				kernel.abs(slot, ABS_MT_POSITION_X, kernel.axes[slot][ABS_MT_POSITION_X] + dx)
				kernel.abs(slot, ABS_MT_POSITION_Y, kernel.axes[slot][ABS_MT_POSITION_Y] + dy)
			end
			kernel.syn()
		end
	end

	--- One finger travels alone by (dx, dy) per frame.
	function kernel.move_slot(slot, steps, dx, dy)
		for _ = 1, steps do
			kernel.abs(slot, ABS_MT_POSITION_X, kernel.axes[slot][ABS_MT_POSITION_X] + dx)
			kernel.abs(slot, ABS_MT_POSITION_Y, kernel.axes[slot][ABS_MT_POSITION_Y] + dy)
			kernel.syn()
		end
	end

	--- The fingers leave; `during` runs between the contacts and the keys.
	function kernel.lift(order, during)
		for _, slot in ipairs(order or { 0, 1, 2 }) do kernel.abs(slot, ABS_MT_TRACKING_ID, -1) end
		if during then during() end
		kernel.key(BTN_TOOL_TRIPLETAP, 0); kernel.key(BTN_TOUCH, 0)
		kernel.syn()
	end

	--- The reader backend over this kernel: read(2), EVIOCGABS and EVIOCGMTSLOTS.
	function kernel.backend(codec, requests)
		return {
			open = function() return 7 end,
			close = function() return true end,
			read = function(_, count)
				local event = table.remove(kernel.unread, 1)
				if not event then return nil, "would_block" end
				local bytes = codec.encode(event[1], event[2], event[3], codec.native_size(), event[4])
				helpers.assert_eq(#bytes, count)
				return bytes
			end,
			read_abs = function(_, request)
				requests[#requests + 1] = request
				if not kernel.answers_registers then return nil, "EVIOCGABS failed (errno=19)" end
				if request ~= 0x8018456f then return nil, "only ABS_MT_SLOT is modelled" end
				return { kernel.slot, 0, SLOT_COUNT - 1, 0, 0, 0 }
			end,
			read_mt_slots = function(_, request, code, count)
				requests[#requests + 1] = request
				if not kernel.answers_registers then return nil, "EVIOCGMTSLOTS failed (errno=19)" end
				local values = {}
				for index = 1, count do values[index] = kernel.axes[index - 1][code] end
				return values
			end,
		}
	end

	return kernel
end




-- =========================================
-- =========================================
-- ======= 2/ The gesture chain ============
-- =========================================
-- =========================================

--- Runs a scenario through the manager's own start_reading and pump.
--- @param scenario function(kernel, pump) Drives the kernel; pump() drains the reader.
--- @param prepare function|nil(kernel) Runs before the reader opens.
--- @return table result { gestures, lines, requests }
local function run(scenario, prepare)
	local names = { MANAGER, READER, FINDER, EMITTER, LOGGER, DECODER }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	-- The decoder logs through the recorder below, so it is loaded after it.
	package.loaded[DECODER] = nil
	local result = { gestures = {}, lines = {}, requests = {} }
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
		package.loaded[EMITTER] = { press = function() return true end, can_fallback = function() return false end }
		local real_finder = helpers.load_module(FINDER)
		package.loaded[FINDER] = setmetatable({
			find = function()
				return { path = "/dev/input/event7", name = "Model Touchpad", is_touchpad = true, semi_mt = false,
					max_fingers = 5 }
			end,
			read_resolution = function() return 10, 10 end,
		}, { __index = real_finder })
		local kernel = new_kernel()
		if prepare then prepare(kernel) end
		local reader = helpers.load_module(READER)
		reader._set_backend(kernel.backend(require("platform.input.event"), result.requests))
		local manager = helpers.load_module(MANAGER)
		manager.init({ enabled = false, persist = false })
		helpers.assert_true(manager.set_action("swipe_3_right", "enter"))
		helpers.assert_true(manager.set_action("swipe_3_up", "enter"))
		-- One dispatch per completed swipe, whatever the shipped default mode.
		helpers.assert_true(manager.set_mode("swipe_3_right", "x1"))
		helpers.assert_true(manager.set_mode("swipe_3_up", "x1"))
		local real_dispatch = manager.dispatch_gesture
		manager.dispatch_gesture = function(gesture)
			result.gestures[#result.gestures + 1] = string.format("%d:%s", gesture.fingers, tostring(gesture.direction))
			return real_dispatch(gesture)
		end
		helpers.assert_true(manager.start_reading(), "the model pad opens through the real reader")
		helpers.assert_true(manager.enable())
		scenario(kernel, function() repeat until (manager.pump() or 0) == 0 end)
		helpers.assert_true(manager.stop_reading())
		reader._reset_backend()
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
	return result
end

--- Whether a logged line contains every needle.
local function logged(lines, ...)
	local needles = { ... }
	for _, line in ipairs(lines) do
		local all = true
		for _, needle in ipairs(needles) do if not line:find(needle, 1, true) then all = false; break end end
		if all then return true end
	end
	return false
end

--- A swipe up whose lift the reader lost (so the swipe is dropped), then the
--- reader catching up: it queries the registers as the kernel holds them then.
local function lost_lift(kernel, pump)
	kernel.land(10, 1000, 900); kernel.move(8, 0, -60); pump()
	kernel.lift(nil, kernel.overflow); pump()
end

--- Then three fingers land where it ended and swipe right: they omit every Y,
--- which only the re-read knows.
local function lost_lift_then_swipe_right(kernel, pump)
	lost_lift(kernel, pump)
	kernel.land(20, 1000, 420); kernel.move(8, 60, 0); kernel.lift(); pump()
end




-- =========================================
-- =========================================
-- ======= 3/ Cases ========================
-- =========================================
-- =========================================

helpers.describe("mt-register-resync: kernel registers re-read", function()
	helpers.it("mt-register-resync: the reader encodes EVIOCGABS and EVIOCGMTSLOTS as the kernel defines them", function()
		local result = run(function() end)
		-- EVIOCGABS(ABS_MT_SLOT) = _IOR('E', 0x40 + 0x2f, 24 bytes); EVIOCGMTSLOTS(4 * (1 + 5)).
		helpers.assert_eq(result.requests[1], 0x8018456f)
		helpers.assert_eq(result.requests[2], 0x8018450a)
	end)

	helpers.it("mt-register-resync: a swipe after SYN_DROPPED on retained coordinates fires", function()
		local result = run(lost_lift_then_swipe_right)
		helpers.assert_eq(result.gestures, { "3:right" },
			"the second swipe's contacts omit Y; only the kernel's registers give it")
		helpers.assert_true(logged(result.lines, "registers re-read after SYN_DROPPED"))
	end)

	helpers.it("mt-register-resync: the selected slot is the kernel's after SYN_DROPPED", function()
		-- The lost lift ends on slot 2 and the next landing starts there, so the
		-- kernel sends no ABS_MT_SLOT before it: on slot 0 that contact is lost,
		-- and the one finger that travels (slot 2's) would read as a still tap.
		local result = run(function(kernel, pump)
			lost_lift(kernel, pump)
			kernel.land(20, 600, 200, { 2, 1, 0 }); kernel.move_slot(2, 8, 120, 0); kernel.lift(); pump()
		end)
		helpers.assert_eq(result.gestures, { "3:right" })
	end)

	helpers.it("mt-register-resync: a touch held across the loss still owns no gesture", function()
		local result = run(function(kernel, pump)
			kernel.land(10, 1000, 900); kernel.move(2, 0, -60); pump()
			kernel.move(1, 0, -60); kernel.overflow()
			kernel.move(6, 0, -60); kernel.lift(); pump()
			kernel.land(20, 1000, 300); kernel.move(8, 60, 0); kernel.lift(); pump()
		end)
		helpers.assert_eq(result.gestures, { "3:right" }, "the interrupted swipe is dropped, the next one fires")
	end)

	helpers.it("mt-register-resync: the first gesture after open uses the coordinates retained before it", function()
		local result = run(function(kernel, pump)
			kernel.land(20, 1000, 420); kernel.move(8, 60, 0); kernel.lift(); pump()
		end, function(kernel)
			-- A swipe before the daemon opened the pad: its coordinates stay in the kernel.
			kernel.land(10, 1000, 900); kernel.move(8, 0, -60); kernel.lift(); kernel.unread = {}
		end)
		helpers.assert_eq(result.gestures, { "3:right" })
		helpers.assert_true(logged(result.lines, "multitouch registers read at open, slot 2 selected"))
	end)

	helpers.it("mt-register-resync: an unreadable register set is said, and the reader keeps going", function()
		local result = run(function(kernel, pump)
			kernel.answers_registers = false
			lost_lift_then_swipe_right(kernel, pump)
			kernel.land(30, 500, 200); kernel.move(8, 60, 0); kernel.lift(); pump()
		end)
		helpers.assert_eq(result.gestures, { "3:right" },
			"without the registers the swipe on retained coordinates is missed; a fresh one fires")
		helpers.assert_true(logged(result.lines, "Touchpad registers unreadable after SYN_DROPPED", "errno=19"))
	end)
end)

helpers.describe("mt-register-resync: decoder seeding contract", function()
	local Decoder = helpers.load_module("modules.gestures.mt_decoder")

	helpers.it("mt-register-resync: refuses a malformed snapshot and a touch in progress", function()
		local decoder = Decoder.new()
		helpers.assert_eq(select(2, decoder:resync({ current_slot = -1, slots = {} })), "the selected slot is not a slot index")
		helpers.assert_eq(select(2, decoder:resync({ current_slot = 0, slots = { [0] = { id = 1, x = 2 } } })),
			"slot 0 has no y register")
		decoder:feed({ type = EV_KEY, code = BTN_TOUCH, value = 1 })
		helpers.assert_eq(select(2, decoder:resync({ current_slot = 0, slots = {} })), "a touch is in progress")
	end)

	helpers.it("mt-register-resync: refuses a query_registers that is not a function", function()
		helpers.assert_eq(pcall(Decoder.new, { query_registers = true }), false)
	end)
end)
