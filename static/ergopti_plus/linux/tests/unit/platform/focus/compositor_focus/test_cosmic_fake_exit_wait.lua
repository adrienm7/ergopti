--- tests/unit/platform/focus/compositor_focus/test_cosmic_fake_exit_wait.lua

--- ==============================================================================
--- MODULE: COSMIC fake — the worker's exit is awaited in wall-clock time
--- DESCRIPTION:
--- tests/hardware/run_cosmic_toplevel_fake.lua reaps its worker after the
--- compositor finishes. It used to call serve(20) a hundred times between two
--- reaps; once the worker closed its connection, each call read end of file and
--- returned at once, so the hundred calls took well under a millisecond and a
--- worker still tearing down read as « kept running after the compositor
--- finished » (dev run 45119239568). The wait now goes through
--- tests/hardware/lib/child_exit.lua, bounded by the monotonic clock.
--- ==============================================================================

local helpers = require("tests.helpers")

local FAKE = "tests/hardware/run_cosmic_toplevel_fake.lua"

local function read(relative)
	local handle = assert(io.open(helpers.driver_root() .. "/" .. relative, "rb"), relative)
	local text = handle:read("*a")
	handle:close()
	return text
end

helpers.describe("COSMIC toplevel fake: the worker's exit wait", function()
	helpers.it("(wayland-desktop-focus) the fake reaps its worker through the wall-clock wait", function()
		local text = read(FAKE)
		helpers.assert_true(text:find('require("tests.hardware.lib.child_exit")', 1, true) ~= nil,
			"the fake loads the shared exit wait")
		helpers.assert_true(text:find("ChildExit.wait(child, ", 1, true) ~= nil,
			"the worker's exit is awaited by ChildExit.wait")
		helpers.assert_true(text:find("waitpid", 1, true) == nil,
			"no reap of its own: a loop counted in serve calls bounds nothing once the socket is closed")
	end)
end)

-- A real child process: fork and execvp need a POSIX kernel and LuaJIT's FFI.
if package.config:sub(1, 1) == "/" and pcall(require, "ffi") then
	local ffi = require("ffi")
	local ChildExit = require("tests.hardware.lib.child_exit")
	ffi.cdef([[
		int ergopti_exit_wait_test_fork(void) __asm__("fork");
		int ergopti_exit_wait_test_execvp(const char *file, char *const argv[]) __asm__("execvp");
		void ergopti_exit_wait_test_exit(int status) __asm__("_exit");
		int ergopti_exit_wait_test_kill(int pid, int signal) __asm__("kill");
	]])

	--- Starts `sleep seconds` as a child of this process.
	--- @return number pid
	local function sleeper(seconds)
		local strings = { "sleep", seconds }
		local argv = ffi.new("char *[3]")
		local anchor = {}
		for index, text in ipairs(strings) do
			anchor[index] = ffi.new("char[?]", #text + 1, text)
			argv[index - 1] = anchor[index]
		end
		local pid = ffi.C.ergopti_exit_wait_test_fork()
		if pid == 0 then
			ffi.C.ergopti_exit_wait_test_execvp("sleep", argv)
			ffi.C.ergopti_exit_wait_test_exit(127)
		end
		assert(pid > 0, "fork refused")
		return pid
	end

	--- A serve loop over a closed connection: it never waits.
	local function closed_connection()
		return false
	end

	helpers.describe("child_exit: an owned child's exit, bounded in wall-clock time", function()
		helpers.it("(wayland-desktop-focus) reaps a child that exits after its connection closed", function()
			local started = ChildExit.now_ms()
			local exited, status = ChildExit.wait(sleeper("0.3"), 5000, closed_connection)
			local elapsed = ChildExit.now_ms() - started
			helpers.assert_true(exited, "a child that exits within the budget is reaped")
			helpers.assert_eq(status, 0, "sleep exits with 0")
			helpers.assert_true(elapsed >= 250, "the wait lasted until the child exited, " .. elapsed .. " ms")
		end)

		helpers.it("(wayland-desktop-focus) gives up only once the budget has passed on the clock", function()
			local child = sleeper("5")
			local started = ChildExit.now_ms()
			local exited = ChildExit.wait(child, 200, closed_connection)
			local elapsed = ChildExit.now_ms() - started
			ffi.C.ergopti_exit_wait_test_kill(child, 9)
			local reaped = ChildExit.wait(child, 5000)
			helpers.assert_true(not exited, "a child that outlives the budget is reported running")
			helpers.assert_true(elapsed >= 200, "a serve that never waits does not shorten the budget, "
				.. elapsed .. " ms")
			helpers.assert_true(reaped, "the killed child is reaped")
		end)
	end)
end
