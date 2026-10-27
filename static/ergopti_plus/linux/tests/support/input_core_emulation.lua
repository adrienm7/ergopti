--- tests/support/input_core_emulation.lua

--- ==============================================================================
--- MODULE: Emulated Linux Input Core For The Gesture Round Trip
--- DESCRIPTION:
--- Runs tests/hardware/run_gesture_roundtrip.lua unchanged on a host without
--- /dev/uinput. The FFI that harness writes through is replaced by a model of
--- the kernel's input core: an event type or MSC code the device did not
--- advertise is dropped, an MT axis or key whose value did not change is
--- dropped, a value for another slot is preceded by the ABS_MT_SLOT the kernel
--- inserts, and a SYN_REPORT with nothing queued is never delivered. The
--- driver's finder and reader are stubbed to hand that output to the real
--- decoder; every stub and global is restored before run() returns.
--- ==============================================================================

local M = {}

local EV_SYN, EV_KEY, EV_ABS, EV_MSC = 0x00, 0x01, 0x03, 0x04
local ABS_MT_SLOT = 0x2f
local UI_SET_EVBIT, UI_SET_MSCBIT = 0x40045564, 0x40045568
local EVENT_BYTES = 24
local DEVICE = { name = "Ergopti Roundtrip Touchpad", path = "/dev/input/emulated", max_fingers = 5 }

--- Builds one emulated device and the fake FFI that writes into it.
--- @param options table { advertise_msc = boolean } false drops every EV_MSC
---   advertisement, as a device that never stamps its reports.
--- @return table ffi, function drain
local function emulated_device(options)
	local evbits, mscbits = {}, {}
	local slot, reported_slot = 0, 0
	local axes, keys = {}, {}
	local queue, delivered = {}, {}

	local function push(etype, code, value)
		queue[#queue + 1] = { type = etype, code = code, value = value }
	end

	local function write(event)
		local etype, code, value = tonumber(event.type), tonumber(event.code), tonumber(event.value)
		if not evbits[etype] then return end
		if etype == EV_ABS and code == ABS_MT_SLOT then
			slot = value
		elseif etype == EV_ABS then
			axes[slot] = axes[slot] or {}
			if axes[slot][code] ~= value then
				axes[slot][code] = value
				if slot ~= reported_slot then
					push(EV_ABS, ABS_MT_SLOT, slot)
					reported_slot = slot
				end
				push(etype, code, value)
			end
		elseif etype == EV_KEY then
			if (keys[code] or 0) ~= value then
				keys[code] = value
				push(etype, code, value)
			end
		elseif etype == EV_MSC then
			if mscbits[code] then push(etype, code, value) end
		elseif etype == EV_SYN then
			if #queue > 0 then
				for _, queued in ipairs(queue) do delivered[#delivered + 1] = queued end
				delivered[#delivered + 1] = { type = EV_SYN, code = 0, value = 0 }
			end
			queue = {}
		end
	end

	local C = {
		open = function() return 7 end,
		close = function() return 0 end,
		ioctl = function(_, request, value)
			local number = tonumber(value)
			if request == UI_SET_EVBIT and (number ~= EV_MSC or options.advertise_msc) then
				evbits[number] = true
			elseif request == UI_SET_MSCBIT then
				mscbits[number] = true
			end
			return 0
		end,
		write = function(_, event)
			write(event)
			return EVENT_BYTES
		end,
	}
	local ffi = {
		C = C,
		cdef = function() end,
		new = function() return {} end,
		cast = function(_, value) return value end,
		sizeof = function() return EVENT_BYTES end,
		copy = function() end,
	}

	local function drain(callback)
		local batch = delivered
		delivered = {}
		for _, event in ipairs(batch) do callback(event) end
		return #batch
	end
	return ffi, drain
end

--- Runs the hardware round trip against the emulated input core.
--- @param harness_path string Absolute path of run_gesture_roundtrip.lua.
--- @param options table { advertise_msc = boolean }
--- @return integer exit_code, string[] printed_lines
function M.run(harness_path, options)
	assert(type(harness_path) == "string" and harness_path ~= "", "the harness path is required")
	assert(type(options) == "table" and type(options.advertise_msc) == "boolean",
		"options.advertise_msc must be a boolean")
	local ffi, drain = emulated_device(options)
	local Finder = require("modules.gestures.touchpad_finder")
	local Reader = require("adapters.evdev_reader")
	local saved = {
		ffi = package.loaded.ffi, open = io.open, execute = os.execute, exit = os.exit, print = print,
		list = Finder.list, reader_open = Reader.open, reader_close = Reader.close, reader_drain = Reader.drain,
	}
	local lines = {}
	local exit_sentinel = {}
	local code = nil

	package.loaded.ffi = ffi
	io.open = function(path, mode)
		if path == "/dev/uinput" then return { close = function() end } end
		return saved.open(path, mode)
	end
	os.execute = function() return true end
	os.exit = function(value)
		code = value
		error(exit_sentinel, 0)
	end
	print = function(line) lines[#lines + 1] = tostring(line) end
	Finder.list = function() return { DEVICE } end
	Reader.open = function() return true end
	Reader.close = function() end
	Reader.drain = function(callback) return drain(callback) end

	local ok, failure = pcall(dofile, harness_path)

	package.loaded.ffi = saved.ffi
	io.open, os.execute, os.exit, print = saved.open, saved.execute, saved.exit, saved.print
	Finder.list = saved.list
	Reader.open, Reader.close, Reader.drain = saved.reader_open, saved.reader_close, saved.reader_drain

	if not ok and failure ~= exit_sentinel then error(failure, 0) end
	assert(type(code) == "number", "the round trip must end with an explicit exit code")
	return code, lines
end

return M
