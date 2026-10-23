--- tests/unit/infra/lifecycle/test_session_lock.lua

--- ==============================================================================
--- MODULE: Graphical Session Lock Regression
--- DESCRIPTION:
--- Runs the real launcher and daemon bootstrap with external child processes.
--- Kernel flock ownership must disappear with the daemon, including on crash.
--- ==============================================================================

local helpers = require("tests.helpers")
local shell_quote = require("text_utils").shell_quote

helpers.describe("Graphical session lock ownership", function()
	helpers.it("allows direct CLI startup without a launcher marker (session-lock-cli)", function()
		helpers.assert_eq(os.getenv("ERGOPTI_SESSION_LOCK_FD"), nil)
		helpers.assert_eq(require("infra.session_lock").protect(), true)
	end)

	helpers.it("takes the instance lock itself when no launcher did, once per process (session-lock-acquire)", function()
		local ffi = require("ffi")
		pcall(ffi.cdef, "int setenv(const char *name, const char *value, int overwrite); int unsetenv(const char *name);")
		local runtime = os.tmpname()
		os.remove(runtime)
		runtime = runtime .. ".runtime"
		local previous = os.getenv("XDG_RUNTIME_DIR")
		helpers.assert_eq(ffi.C.setenv("XDG_RUNTIME_DIR", runtime, 1), 0)
		local first = require("infra.session_lock")
		local second
		local ok, failure = pcall(function()
			helpers.assert_eq(first.acquire(), true)
			-- The entry is loaded several times in one process by tests: the owner must not contend with itself.
			helpers.assert_eq(first.acquire(), true)
			-- A different module instance stands for a second daemon process: the held lock refuses it.
			package.loaded["infra.session_lock"] = nil
			second = require("infra.session_lock")
			local acquired, reason, contended = second.acquire()
			helpers.assert_eq(acquired, false)
			helpers.assert_eq(contended, true)
			helpers.assert_true(reason:find("already running", 1, true) ~= nil, reason)
			first.release()
			helpers.assert_eq(second.acquire(), true, "the lock is free once its owner released it")
		end)
		first.release()
		if second then second.release() end
		package.loaded["infra.session_lock"] = first
		if previous then ffi.C.setenv("XDG_RUNTIME_DIR", previous, 1) else ffi.C.unsetenv("XDG_RUNTIME_DIR") end
		os.execute("rm -rf " .. shell_quote(runtime))
		if not ok then error(failure, 0) end
	end)

	helpers.it("releases the actual lock after daemon exit with a live child (session-lock-native)", function()
		local fixture = helpers.driver_root() .. "/tests/hardware/test_session_lock.py"
		local status = os.execute("python3 " .. shell_quote(fixture))
		helpers.assert_true(status == 0 or status == true, "Native session lock regression failed")
	end)
end)
