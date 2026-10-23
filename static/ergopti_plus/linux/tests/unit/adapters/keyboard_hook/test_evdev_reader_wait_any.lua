--- tests/unit/adapters/keyboard_hook/test_evdev_reader_wait_any.lua

--- ==============================================================================
--- MODULE: evdev Reader — multi-source wait
--- DESCRIPTION:
--- The idle loop sleeps on every open source (keyboard, pointer, touchpad) so an
--- idle daemon wakes on input instead of spinning. The wait reads nothing and
--- answers nil, not false, when it cannot wait, so the loop yields another way
--- instead of mistaking "could not wait" for "waited and nothing came".
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.evdev_reader_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.evdev_reader_fixture")
local helpers, recorder = Fixture.helpers, Fixture.recorder

--- A recorder whose multi-descriptor wait logs the descriptors and answers `ready`.
--- @param ready boolean What the wait reports.
--- @return table backend, table waits
local function waiting_backend(ready)
	local backend = recorder()
	local waits = {}
	local next_fd = 10
	backend.open = function() next_fd = next_fd + 1; return next_fd end
	backend.poll_many = function(fds, count, timeout_ms)
		local copy = {}
		for index = 1, count do copy[index] = fds[index] end
		waits[#waits + 1] = { fds = copy, timeout_ms = timeout_ms }
		return ready
	end
	return backend, waits
end

helpers.describe("evdev_reader: wait_any_readable", function()
	helpers.it("answers nil with no backend or no open source", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		helpers.assert_nil(reader.wait_any_readable(8))
		local backend = waiting_backend(true)
		reader._set_backend(backend)
		helpers.assert_nil(reader.wait_any_readable(8), "nothing is open yet")
		reader._reset_backend()
	end)

	helpers.it("answers nil when the backend cannot wait on several descriptors", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = recorder()
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		helpers.assert_nil(reader.wait_any_readable(8))
		reader._reset_backend()
	end)

	helpers.it("waits on every open source at once and reports readiness", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, waits = waiting_backend(true)
		reader._set_backend(backend)
		reader.open("/dev/input/event3", reader.KEYBOARD)
		reader.open("/dev/input/event5", reader.POINTER)
		helpers.assert_eq(reader.wait_any_readable(8), true)
		helpers.assert_eq(#waits, 1)
		helpers.assert_eq(waits[1].timeout_ms, 8)
		table.sort(waits[1].fds)
		helpers.assert_eq(waits[1].fds, { 11, 12 }, "both sources are in the wait")
		reader._reset_backend()
	end)

	helpers.it("reports a quiet wait as false and drops a closed source", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend, waits = waiting_backend(false)
		reader._set_backend(backend)
		reader.open("/dev/input/event3", reader.KEYBOARD)
		reader.open("/dev/input/event5", reader.POINTER)
		reader.close(reader.POINTER)
		helpers.assert_eq(reader.wait_any_readable(4), false)
		helpers.assert_eq(waits[1].fds, { 11 }, "a closed source is no longer waited on")
		reader._reset_backend()
	end)

	helpers.it("answers nil, not false, when the backend wait raises", function()
		local reader = helpers.load_module("adapters.evdev_reader")
		local backend = waiting_backend(true)
		backend.poll_many = function() error("poll refused") end
		reader._set_backend(backend)
		reader.open("/dev/input/event3")
		helpers.assert_nil(reader.wait_any_readable(8))
		reader._reset_backend()
	end)
end)

-- The real poll(2) through the FFI backend, on a FIFO standing in for a device.
if package.config:sub(1, 1) == "/" and pcall(require, "ffi") then
	helpers.describe("evdev_reader: wait_any_readable on a real descriptor", function()
		helpers.it("wakes at once for data and times out when quiet", function()
			local reader = helpers.load_module("adapters.evdev_reader")
			local path = os.tmpname()
			os.remove(path)
			local made = os.execute("mkfifo '" .. path .. "'")
			helpers.assert_true(made == true or made == 0, "mkfifo failed")
			helpers.assert_true(reader.use_ffi_backend())
			helpers.assert_true(reader.open(path, reader.KEYBOARD))
			helpers.assert_eq(reader.wait_any_readable(0), false, "a quiet source times out")
			local writer = assert(io.open(path, "wb"))
			writer:write("x"); writer:flush()
			local luv = require("luv")
			local started = luv.hrtime()
			helpers.assert_eq(reader.wait_any_readable(2000), true, "data wakes the wait")
			-- Counted outcome plus a generous ceiling: a wake takes microseconds,
			-- the timeout it replaced two seconds.
			helpers.assert_true((luv.hrtime() - started) / 1e6 < 1500, "the wait did not return at once")
			writer:close()
			reader.close(reader.KEYBOARD)
			reader._reset_backend()
			os.remove(path)
		end)
	end)
end
