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
--- The kernel is tests/support/touchpad_kernel_model.lua; the reader, the
--- manager and the decoder are the real ones.
--- ==============================================================================

local helpers = require("tests.helpers")

local Kernel = require("tests.support.touchpad_kernel_model")

local MANAGER, READER, FINDER = "modules.gestures.manager", "platform.input.evdev_reader", "modules.gestures.touchpad_finder"
local EMITTER, LOGGER = "modules.gestures.combo_emitter", "core.logger.engine.shim"
local DECODER = "modules.gestures.mt_decoder"
local EV_KEY, BTN_TOUCH = 0x01, 0x14a




-- =========================================
-- =========================================
-- ======= 1/ The gesture chain ============
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
		local kernel = Kernel.new()
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
-- ======= 2/ Cases ========================
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
