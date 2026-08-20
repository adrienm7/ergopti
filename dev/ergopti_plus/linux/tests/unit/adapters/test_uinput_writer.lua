--- tests/unit/adapters/test_uinput_writer.lua

--- ==============================================================================
--- MODULE: uinput Writer Contract
--- DESCRIPTION:
--- Pins the non-forking emit channel: the exact bytes it puts on /dev/uinput,
--- the order it configures the device in, and the fact that emitting does not
--- spawn anything.
---
--- WHY BYTE-LEVEL:
--- This adapter's entire job is to hand the kernel a correctly-shaped
--- `struct input_event`. A wrong field offset does not raise — write() returns
--- the byte count either way — it just produces a key nobody pressed, or
--- nothing at all. There is no return value to assert and no exception to catch,
--- so the bytes ARE the contract. Checking "open() returned true" would pass on
--- an adapter that writes 24 zero bytes.
---
--- WHY IT NEEDS NO HARDWARE:
--- All syscalls go through a swappable backend. These tests bind a recorder, so
--- the encoding and the ioctl sequence are verified on any interpreter, with no
--- /dev/uinput and no LuaJIT. What still needs real hardware is only the last
--- link — that the kernel accepts the device — and that is precisely the part
--- these assertions make safe to attempt.
--- ==============================================================================

local helpers = require("tests.helpers")


--- A recording backend: captures every syscall instead of performing one.
--- @param opts table|nil { fail_on = "open"|"ioctl"|"write", fail_req = integer }
local function recorder(opts)
	opts = opts or {}
	local rec = { opened = {}, ioctls = {}, writes = {}, closed = 0 }
	rec.backend = {
		open = function(path)
			rec.opened[#rec.opened + 1] = path
			if opts.fail_on == "open" then return nil, "stubbed failure" end
			return 42 -- a plausible fd
		end,
		ioctl = function(fd, request, arg)
			rec.ioctls[#rec.ioctls + 1] = { fd = fd, request = request, arg = arg }
			if opts.fail_on == "ioctl" and request == opts.fail_req then return false end
			return true
		end,
		write = function(fd, bytes)
			rec.writes[#rec.writes + 1] = bytes
			if opts.fail_on == "write" then return false end
			return true
		end,
		close = function() rec.closed = rec.closed + 1 end,
	}
	return rec
end

--- Reads `width` little-endian bytes back out of an encoded struct.
local function le(str, offset, width)
	local n, mul = 0, 1
	for i = offset, offset + width - 1 do
		n = n + str:byte(i) * mul
		mul = mul * 256
	end
	return n
end





-- ====================================================
-- ====================================================
-- ======= 1/ The wire format the kernel reads ========
-- ====================================================
-- ====================================================

helpers.describe("uinput_writer: struct input_event encoding", function()

	helpers.it("is exactly 24 bytes with the fields at the 64-bit offsets", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local ev = U.encode_event(U.EV_KEY, 30, 1)

		helpers.assert_eq(#ev, U.INPUT_EVENT_SIZE,
			"struct input_event is 24 bytes on 64-bit (timeval 16 + type 2 + code 2 + value 4); "
			.. "a short struct makes the kernel read the next event's bytes as this one's fields")

		-- timeval occupies bytes 1..16 and is left zero: the kernel stamps events
		-- arriving from uinput itself.
		helpers.assert_eq(le(ev, 1, 8), 0, "tv_sec must default to 0")
		helpers.assert_eq(le(ev, 9, 8), 0, "tv_usec must default to 0")

		helpers.assert_eq(le(ev, 17, 2), U.EV_KEY, "type must sit at offset 16 (1-based 17)")
		helpers.assert_eq(le(ev, 19, 2), 30, "code must sit at offset 18 (1-based 19)")
		helpers.assert_eq(le(ev, 21, 4), 1, "value must sit at offset 20 (1-based 21)")
	end)

	helpers.it("packs little-endian, so a multi-byte code is not byte-swapped", function()
		local U = helpers.load_module("adapters.uinput_writer")
		-- 0x0130 = KEY_MAX-ish territory; the two bytes must be 0x30, 0x01.
		local ev = U.encode_event(U.EV_KEY, 0x0130, 1)
		helpers.assert_eq(ev:byte(19), 0x30, "low byte of code first")
		helpers.assert_eq(ev:byte(20), 0x01, "high byte of code second")
	end)

	helpers.it("encodes a negative value as two's complement", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local ev = U.encode_event(U.EV_KEY, 30, -1)
		helpers.assert_eq(le(ev, 21, 4), 0xFFFFFFFF,
			"value is __s32; -1 must be 0xFFFFFFFF, not a truncated 0")
	end)

	helpers.it("encodes uinput_setup as 92 bytes with a NUL-padded name", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local setup = U.encode_setup()
		helpers.assert_eq(#setup, 92,
			"struct uinput_setup is input_id (8) + name[80] + ff_effects_max (4); the ioctl "
			.. "request number itself encodes that size, so a different length is rejected")
		helpers.assert_eq(setup:sub(9, 16), "Ergopti ",
			"the device name starts at offset 8, right after struct input_id")
		helpers.assert_eq(setup:byte(88), 0, "name[] must be NUL-padded to its full 80 bytes")
	end)

end)





-- ====================================================
-- ====================================================
-- ======= 2/ Device creation order ===================
-- ====================================================
-- ====================================================

helpers.describe("uinput_writer: device creation", function()

	helpers.it("registers every capability BEFORE UI_DEV_CREATE", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder()
		U._set_backend(rec.backend)

		helpers.assert_true(U.open(), "open() must succeed against a working backend")

		local create_at = nil
		local last_capability_at = 0
		for i, call in ipairs(rec.ioctls) do
			if call.request == U.UI_DEV_CREATE then create_at = i end
			if call.request == U.UI_SET_EVBIT or call.request == U.UI_SET_KEYBIT then
				last_capability_at = i
			end
		end

		helpers.assert_true(create_at ~= nil, "UI_DEV_CREATE must be issued")
		helpers.assert_true(last_capability_at < create_at,
			"every UI_SET_EVBIT/UI_SET_KEYBIT must precede UI_DEV_CREATE: the kernel freezes the "
			.. "capability bits at creation, and a key registered afterwards succeeds while doing "
			.. "nothing — which surfaces only as one key silently not working")

		U._reset_backend()
	end)

	helpers.it("registers EV_KEY and the full keycode range it claims", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder()
		U._set_backend(rec.backend)
		U.open()

		local keybits, saw_ev_key, saw_ev_syn = {}, false, false
		for _, call in ipairs(rec.ioctls) do
			if call.request == U.UI_SET_KEYBIT then keybits[call.arg] = true end
			if call.request == U.UI_SET_EVBIT and call.arg == U.EV_KEY then saw_ev_key = true end
			if call.request == U.UI_SET_EVBIT and call.arg == U.EV_SYN then saw_ev_syn = true end
		end

		helpers.assert_true(saw_ev_key, "EV_KEY must be enabled or the device reports no keys at all")
		helpers.assert_true(saw_ev_syn, "EV_SYN must be enabled or no SYN_REPORT is ever delivered")
		for code = 1, U.KEY_CODE_MAX do
			helpers.assert_true(keybits[code] == true,
				"keycode " .. code .. " was never registered — an unregistered code is dropped "
				.. "silently by the kernel, so that one key would simply stop working under a grab")
		end

		U._reset_backend()
	end)

	helpers.it("passes the 92-byte setup struct to UI_DEV_SETUP, not an integer", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder()
		U._set_backend(rec.backend)
		U.open()

		local setup_arg = nil
		for _, call in ipairs(rec.ioctls) do
			if call.request == U.UI_DEV_SETUP then setup_arg = call.arg end
		end
		helpers.assert_eq(type(setup_arg), "string", "UI_DEV_SETUP takes a struct, not a scalar")
		helpers.assert_eq(#setup_arg, 92, "the struct must be the size the ioctl number encodes")

		U._reset_backend()
	end)

	helpers.it("closes the descriptor and reports failure when an ioctl fails", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder({ fail_on = "ioctl", fail_req = 0x5501 }) -- UI_DEV_CREATE
		U._set_backend(rec.backend)

		helpers.assert_eq(U.open(), false, "a failed UI_DEV_CREATE must not report success")
		helpers.assert_eq(U.is_open(), false, "a failed open must leave the channel closed")
		helpers.assert_true(rec.closed >= 1,
			"the descriptor must be closed on the failure path — leaking it holds /dev/uinput open "
			.. "for the life of the daemon")

		U._reset_backend()
	end)

end)





-- ====================================================
-- ====================================================
-- ======= 3/ Emission ================================
-- ====================================================
-- ====================================================

helpers.describe("uinput_writer: emission", function()

	helpers.it("writes the key event and then a SYN_REPORT", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder()
		U._set_backend(rec.backend)
		U.open()

		local before = #rec.writes
		helpers.assert_true(U.emit(30, 1), "emit must report success against a working backend")
		helpers.assert_eq(#rec.writes - before, 2,
			"one key event plus one SYN_REPORT: without the SYN the kernel buffers the key and the "
			.. "application sees nothing, while every write still returns success")

		local key_ev = rec.writes[#rec.writes - 1]
		local syn_ev = rec.writes[#rec.writes]
		helpers.assert_eq(le(key_ev, 17, 2), U.EV_KEY, "the first write must be the EV_KEY event")
		helpers.assert_eq(le(key_ev, 19, 2), 30, "…carrying the requested keycode")
		helpers.assert_eq(le(syn_ev, 17, 2), U.EV_SYN, "the second write must be EV_SYN")
		helpers.assert_eq(le(syn_ev, 19, 2), U.SYN_REPORT, "…with code SYN_REPORT")
		helpers.assert_eq(le(syn_ev, 21, 4), 0, "…and value 0")

		U._reset_backend()
	end)

	helpers.it("passes the autorepeat value through unchanged", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder()
		U._set_backend(rec.backend)
		U.open()

		U.emit(30, 2)
		local key_ev = rec.writes[#rec.writes - 1]
		helpers.assert_eq(le(key_ev, 21, 4), 2,
			"an autorepeat (value 2) must be re-emitted as 2. The ydotool wire format has no "
			.. "representation for it and collapses it into a fresh press; this channel does not "
			.. "have to, and a pass-through that rewrites what it passes is not a pass-through")

		U._reset_backend()
	end)

	helpers.it("refuses to emit when the device was never opened", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder()
		U._set_backend(rec.backend)

		helpers.assert_eq(U.emit(30, 1), false, "emit must fail loudly before open()")
		helpers.assert_eq(#rec.writes, 0, "…and must not write anything")

		U._reset_backend()
	end)

	helpers.it("reports failure when the SYN write fails", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local ok_rec = recorder()
		U._set_backend(ok_rec.backend)
		U.open()

		-- Fail only the SYN by swapping the backend after the device is created.
		local calls = 0
		ok_rec.backend.write = function(_, bytes)
			calls = calls + 1
			return calls == 1 -- the key succeeds, the SYN does not
		end
		helpers.assert_eq(U.emit(30, 1), false,
			"a key written without its SYN_REPORT is invisible to the application, so reporting "
			.. "success there would hide a dead keystroke")

		U._reset_backend()
	end)

end)





-- ====================================================
-- ====================================================
-- ======= 4/ Availability fails closed ===============
-- ====================================================
-- ====================================================

helpers.describe("uinput_writer: availability", function()

	helpers.it("is unavailable, rather than raising, without FFI or /dev/uinput", function()
		-- This is the state of the machine running these tests: plain Lua, no
		-- /dev/uinput. The module must still LOAD and answer honestly, because
		-- the caller uses that answer to keep its existing channel.
		local U = helpers.load_module("adapters.uinput_writer")
		U._reset_backend()
		local available = U.is_available()
		helpers.assert_eq(type(available), "boolean",
			"is_available() must answer with a boolean rather than raising — the daemon calls it "
			.. "during startup to choose a channel")
	end)

	helpers.it("does not create a device merely by being asked whether it could", function()
		local U = helpers.load_module("adapters.uinput_writer")
		local rec = recorder()
		U._set_backend(rec.backend)

		U.is_available()
		helpers.assert_eq(#rec.ioctls, 0,
			"a probe must have no side effects: is_available() is called on every startup path, "
			.. "and opening a device to answer it would leave a virtual keyboard behind each time")
		helpers.assert_eq(U.is_open(), false, "the probe must not leave the channel open")

		U._reset_backend()
	end)

end)
