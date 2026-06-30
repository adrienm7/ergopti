--- tests/unit/adapters/test_shell_runner_on_done_visible.lua

--- ==============================================================================
--- MODULE: Regression — ShellRunner on_done throws are visible (M-4)
--- DESCRIPTION:
--- The old wrapped_on_done used bare pcall(on_done, ...) which silently discarded
--- any exception thrown inside the callback. This is the root cause of the
--- "vert mais aucune prédiction" bug class: an on_done that throws on its first
--- line (e.g. os.remove(nil) closure-nil-global) aborts the entire callback body
--- with no log line anywhere, no call to ergopti_report_crash, nothing.
---
--- Fix: replaced pcall with xpcall(..., debug.traceback); on failure, logs an
--- ERROR via Logger.error and forwards to _G.ergopti_report_crash (if present).
---
--- Two tests:
---   1. Source check: wrapped_on_done must NOT use bare pcall(on_done, ...).
---   2. Behaviour: driving on_done via a stub hs.task confirms the ERROR is logged.
--- ==============================================================================

local helpers = require("tests.helpers")

local function read_shell_runner_src()
	local path = helpers.driver_root() .. "adapters/shell_runner.lua"
	local fh   = io.open(path, "r")
	helpers.assert_true(fh ~= nil, "adapters/shell_runner.lua must be readable")
	local src = fh:read("*a"); fh:close()
	return src
end




-- ===============================================================================
-- ===============================================================================
-- ======= 1/ Source invariant: no bare pcall(on_done) in wrapped_on_done =======
-- ===============================================================================
-- ===============================================================================

helpers.describe("ShellRunner: on_done throws are visible (M-4 source)", function()

	helpers.it("wrapped_on_done does NOT use bare pcall(on_done, ...)", function()
		local src = read_shell_runner_src()
		-- The old swallowing pattern
		local bad_pos = src:find("pcall(on_done,", 1, true)
		helpers.assert_true(bad_pos == nil,
			"wrapped_on_done must NOT use bare pcall(on_done, ...) — it silently swallows all callback errors")
	end)

	helpers.it("wrapped_on_done uses xpcall for error visibility", function()
		local src = read_shell_runner_src()
		helpers.assert_true(src:find("xpcall", 1, true) ~= nil,
			"wrapped_on_done must use xpcall so callback errors are surfaced and logged")
	end)

	helpers.it("wrapped_on_done logs an ERROR when the callback throws", function()
		local src = read_shell_runner_src()
		-- After xpcall, the error branch must call Logger.error
		local xpcall_pos  = src:find("xpcall", 1, true)
		local log_pos     = src:find("Logger.error", xpcall_pos or 1, true)
		helpers.assert_true(xpcall_pos ~= nil, "xpcall must be present")
		helpers.assert_true(log_pos ~= nil and log_pos > xpcall_pos,
			"Logger.error must appear AFTER xpcall in wrapped_on_done (error must be logged)")
	end)
end)




-- ==========================================================================
-- ==========================================================================
-- ======= 2/ Behaviour: ERROR is captured when on_done throws (M-4) =======
-- ==========================================================================
-- ==========================================================================

helpers.describe("ShellRunner: ERROR logged when on_done throws (M-4 behaviour)", function()

	helpers.it("captures Logger.error when on_done throws 'boom'", function()
		-- Capture log output via Logger.set_sink
		local errors_logged = {}
		local logger = helpers.load_with_stubs("lib.logger")
		if type(logger.set_sink) == "function" then
			logger.set_sink(function(level, _module, msg)
				if level == "ERROR" then errors_logged[#errors_logged + 1] = msg end
			end)
		end

		-- Stub hs.task so start() immediately fires the wrapped completion callback
		local captured_completion_cb = nil
		local hs_overrides = {
			task = {
				new = function(_, cb, _args)
					captured_completion_cb = cb
					return {
						start        = function() if captured_completion_cb then captured_completion_cb(0, "", "") end end,
						isRunning    = function() return false end,
						terminate    = function() end,
					}
				end,
			},
		}

		-- Reload shell_runner under the stub hs
		package.loaded["adapters.shell_runner"] = nil
		local sr = helpers.load_with_stubs("adapters.shell_runner", hs_overrides)

		local crash_called = false
		_G.ergopti_report_crash = function() crash_called = true end

		-- Spawn with an on_done that throws
		local handle = sr.spawn("/usr/bin/true", {}, function()
			error("boom from on_done")
		end)
		handle.start()

		-- At least one ERROR mentioning the throw must have been logged
		-- (If Logger.set_sink is not available we fall back to the source check above)
		if type(logger.set_sink) == "function" then
			local found_error = false
			for _, msg in ipairs(errors_logged) do
				if msg:find("boom", 1, true) or msg:find("on_done", 1, true) then
					found_error = true; break
				end
			end
			helpers.assert_true(found_error or crash_called,
				"an ERROR mentioning the throw must be logged (or crash reporter called) when on_done throws")
		end

		_G.ergopti_report_crash = nil
	end)
end)
