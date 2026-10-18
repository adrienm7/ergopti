--- tests/support/adapters/keyboard_hook/evdev_reader_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_evdev_reader
--- DESCRIPTION:
--- Prelude shared by the test_evdev_reader_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A recording syscall backend.
--- @param events table|nil Encoded struct strings to hand back, in order.
--- @param opts table|nil { open_fails?, ioctl_fails?, read_status?, read_reason?, read_raises? }
--- @return table backend, table log
local function recorder(events, opts)
	opts = opts or {}
	local log = { ioctls = {}, opened = nil, closed = false, reads = 0 }
	local at = 0
	local backend = {
		open = function(path, flags)
			log.opened = { path = path, flags = flags }
			if opts.open_fails then return nil, "denied" end
			return 7
		end,
		ioctl = function(_, request, arg)
			log.ioctls[#log.ioctls + 1] = { request = request, arg = arg, after_reads = log.reads }
			return not opts.ioctl_fails
		end,
		read = function()
			log.reads = log.reads + 1
			if opts.read_raises then error(opts.read_raises) end
			at = at + 1
			local event = (events or {})[at]
			if event ~= nil then return event end
			return nil, opts.read_status, opts.read_reason
		end,
		poll = function() return (events or {})[at + 1] ~= nil end,
		close = function() log.closed = true end,
	}
	return backend, log
end

--- Whether one open(2) flag bit is set, spelled arithmetically because LuaJIT
--- (what CI runs) has no bitwise operators.
--- @param flags integer The flag word the reader passed to open().
--- @param bit integer A single-bit flag value from fcntl.h.
--- @return boolean
local function flag_set(flags, bit)
	return math.floor(flags / bit) % 2 == 1
end

--- Encodes one event the way the kernel would write it.
--- @param ev_type integer
--- @param code integer
--- @param value integer
--- @return string
local function encoded(ev_type, code, value)
	local ie = require("infra.input_event")
	return ie.encode(ev_type, code, value)
end

--- Exercises the actual FFI boundary with controlled symbol providers, never a kernel device.
--- @param rows table Encoded input_event bytes.
--- @param options table|nil Controlled provider callbacks and failures.
--- @param body function Actual reader assertions.
local function controlled_native_reader(rows, options, body)
	options = options or {}
	local old_ffi, old_preload = package.loaded.ffi, package.preload.ffi
	local codec = require("infra.input_event")
	local log = { reads = 0, closes = 0, opens = 0, grabs = 0 }
	local reader
	local symbols = {
		open = function()
			log.opens = log.opens + 1
			if options.before_open then options.before_open(reader) end
			return options.fds and options.fds[log.opens] or options.fd or 7
		end,
		ioctl = function(_, request, buffer)
			log.grabs = log.grabs + 1
			if options.before_ioctl then options.before_ioctl(reader) end
			if options.grab_fails and request == 0x40044590 then return -1 end
			if options.native_bitmaps and (request % 256 == 0x18 or request % 256 == 0x19) then
				local count = math.floor(request / 0x10000) % 0x4000
				buffer.bytes = string.rep("\0", count)
				return count
			end
			return 0
		end,
		read = function(_, buffer)
			if options.before_read then options.before_read(reader) end
			log.reads = log.reads + 1
			local bytes = rows[log.reads]
			if not bytes then return -1 end
			buffer.bytes = bytes
			return #bytes
		end,
		poll = function() return 1 end,
		close = function(fd)
			log.closes = log.closes + 1
			if options.before_close then options.before_close(reader, fd) end
			return options.close_fails and -1 or 0
		end,
	}
	package.loaded.ffi = nil
	package.preload.ffi = function()
		if options.before_load then options.before_load(reader) end
		return {
			cdef = function() if options.before_cdef then options.before_cdef(reader) end end,
			sizeof = function() return 24 end,
			new = function(kind) return kind == "struct pollfd[1]" and { [0] = {} } or { bytes = "" } end,
			cast = function(_, value) return value end,
			string = function(buffer, count)
				if options.before_string then options.before_string(reader) end
				return buffer.bytes:sub(1, count)
			end,
			errno = function() return 11 end,
			C = symbols,
		}
	end
	codec._reset_measurement()
	local called, err = pcall(function()
		reader = helpers.load_module("adapters.evdev_reader")
		body(reader, log, symbols)
	end)
	package.loaded.ffi, package.preload.ffi = old_ffi, old_preload
	codec._reset_measurement()
	if not called then error(err, 0) end
end

--- Runs exact-slot observer controls against explicitly controlled FFI providers.
--- @param single_sided boolean Lua54 permits an equality callback on only one operand.
local function independent_slot_observer_case(single_sided)
	controlled_native_reader({ encoded(1, 30, 1) }, nil, function(reader, log)
		local callbacks, owned = 0, {}
		local mt = { __eq = function()
			callbacks = callbacks + 1
			assert(reader.close(owned))
			return true
		end }
		if not single_sided then setmetatable(owned, mt) end
		local foreign = setmetatable({}, mt)
		assert(reader.open("/dev/input/event3", owned))
		assert(reader.grab(owned))
		local event = assert(reader.read_event(owned))
		local cap = reader.capture_event(event, foreign)
		local unexpected_close_attempts = log.closes
		helpers.assert_eq(reader.close(owned), true)
		helpers.assert_eq(callbacks, 0, "native receipt observation must not invoke a supplied slot metamethod")
		helpers.assert_eq(unexpected_close_attempts, 0, "an alias comparison cannot trigger native session cleanup")
		helpers.assert_eq(cap, nil)
	end)
end

--- Provides controlled native syscall symbols for held-key receipt tests.
--- No kernel descriptor or physical device is acquired by this fixture.
local function controlled_held_reader(options, body)
	options = options or {}
	local saved_ffi, saved_preload = package.loaded.ffi, package.preload.ffi
	local codec = require("infra.input_event")
	local reader
	local log = { queries = 0, led_queries = 0, opens = 0, closes = 0 }
	local function bitmap(count, codes)
		local values = {}
		for index = 1, count do values[index] = 0 end
		for _, code in ipairs(codes or options.down or { 29, 42 }) do
			local index = math.floor(code / 8) + 1
			if index <= count then values[index] = values[index] + 2 ^ (code % 8) end
		end
		local bytes = {}
		for index, value in ipairs(values) do bytes[index] = string.char(value) end
		return table.concat(bytes)
	end
	local symbols = {
		open = function() log.opens = log.opens + 1; return log.opens + 6 end,
		close = function() log.closes = log.closes + 1; return options.close_fails and -1 or 0 end,
		ioctl = function(_, request, buffer)
			if request % 256 == 0x19 then
				log.led_queries = log.led_queries + 1
				local count = math.floor(request / 0x10000) % 0x4000
				if options.before_led_query then options.before_led_query(reader) end
				buffer.bytes = options.led_bytes or bitmap(count, options.leds or { 1 })
				return options.led_copied == nil and count or options.led_copied
			end
			if request % 256 == 0x18 then
				log.queries = log.queries + 1
				local count = math.floor(request / 0x10000) % 0x4000
				if options.before_query then options.before_query(reader) end
				buffer.bytes = options.bytes or bitmap(count)
				return options.copied == nil and count or options.copied
			end
			return options.grab_fails and -1 or 0
		end,
		read = function(_, buffer)
			local bytes = table.remove(options.rows or {}, 1)
			if not bytes then return -1 end
			buffer.bytes = bytes; return #bytes
		end,
		poll = function() return 1 end,
	}
	package.loaded.ffi = nil
	package.preload.ffi = function()
		return {
			cdef = function() end, sizeof = function() return 24 end,
			new = function(kind) return kind == "struct pollfd[1]" and { [0] = {} } or { bytes = "" } end,
			cast = function(_, value) return value end,
			string = function(buffer, count)
				if options.before_string then options.before_string(reader) end
				return buffer.bytes:sub(1, count)
			end,
			errno = function() return 11 end, C = symbols,
		}
	end
	codec._reset_measurement()
	local called, reason = pcall(function()
		reader = helpers.load_module("adapters.evdev_reader")
		body(reader, options, log, symbols)
	end)
	package.loaded.ffi, package.preload.ffi = saved_ffi, saved_preload
	codec._reset_measurement()
	if not called then error(reason, 0) end
end

return {
	helpers = helpers,
	recorder = recorder,
	flag_set = flag_set,
	encoded = encoded,
	controlled_native_reader = controlled_native_reader,
	independent_slot_observer_case = independent_slot_observer_case,
	controlled_held_reader = controlled_held_reader,
}
