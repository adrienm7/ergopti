--- tests/support/adapters/synthetic_input/uinput_writer_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_uinput_writer
--- DESCRIPTION:
--- Prelude shared by the test_uinput_writer_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

--- A recording backend: captures every syscall instead of performing one.
--- @param opts table|nil { fail_on = "open"|"ioctl"|"write", fail_req = integer }
local function recorder(opts)
	opts = opts or {}
	local rec = { opened = {}, open_flags = {}, ioctls = {}, writes = {}, closed = 0 }
	rec.backend = {
		open = function(path, flags)
			rec.opened[#rec.opened + 1] = path
			rec.open_flags[#rec.open_flags + 1] = flags
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





-- ======================================================
-- ======================================================
-- ======= 5/ Exact owned output acknowledgements =======
-- ======================================================
-- ======================================================

--- Opens a recorded native channel with literal retirement acknowledgement.
--- @return table writer, table recorder, table capability
local function owned_channel()
	local writer = helpers.load_module("adapters.uinput_writer")
	local recorded = recorder()
	recorded.backend.close = function() recorded.closed = recorded.closed + 1; return true end
	writer._set_backend(recorded.backend)
	helpers.assert_eq(writer.open(), true)
	return writer, recorded, writer.capture_output()
end

return {
	helpers = helpers,
	recorder = recorder,
	le = le,
	owned_channel = owned_channel,
}
