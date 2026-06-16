--- tests/unit/lib/test_logger_deferred_purge.lua

--- ==============================================================================
--- MODULE: Logger — Deferred Old-Log Purge (perf regression)
--- DESCRIPTION:
--- Locks down that M.init_log_path() does NOT run the old-log purge synchronously:
--- it schedules it via hs.timer so the boot critical path is not blocked.
---
--- ROOT CAUSE ENCODED: the purge spawns a `find | while read … date … rm`
--- pipeline (several subprocesses PER log file) plus a per-sub-file `stat`. Run
--- inline during init_log_path it cost ~0.6 s of synchronous shell forks — a
--- large slice of the boot "Path resolution + log path" phase — for pure
--- housekeeping (deleting stale files). If a future edit moves the purge back
--- inline, the "no find synchronously" assertion fails.
---
--- FEATURES & RATIONALE:
--- 1. ShellRunner stub: records every exec() command so we can assert WHICH
---    shell work runs synchronously vs. deferred. Installed BEFORE requiring the
---    logger so its lazy require resolves to the stub.
--- 2. Timer capture: hs.timer.doAfter is overridden to record the deferred
---    callback without firing it, so we can prove the purge is scheduled and then
---    drive it manually to prove it still runs.
--- 3. Full restore: package.loaded entries and hs.timer.doAfter are restored so
---    no stub leaks into later test files.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stub the shell adapter and reload the logger fresh so init_log_path picks it up.
local _real_logger_loaded = package.loaded["lib.logger"]
local _real_shell_loaded  = package.loaded["adapters.shell_runner"]

local exec_log = {}
package.loaded["adapters.shell_runner"] = {
	exec = function(cmd) exec_log[#exec_log + 1] = tostring(cmd); return "" end,
}
package.loaded["lib.logger"] = nil
local Logger = require("lib.logger")

--- True when any recorded exec command matches a Lua pattern.
local function any_exec_matches(pat)
	for _, c in ipairs(exec_log) do
		if c:find(pat) then return true end
	end
	return false
end

helpers.describe("logger — old-log purge is deferred off the boot path", function()
	helpers.it("init_log_path does NOT run the find-based purge synchronously", function()
		local hs = _G.hs
		local saved_doAfter = hs.timer.doAfter
		local deferred = {}
		-- Record the scheduled callback WITHOUT firing it.
		hs.timer.doAfter = function(_delay, fn) deferred[#deferred + 1] = fn end

		exec_log = {}
		Logger.init_log_path("/tmp/ergopti_test_logs_deferred/", 14)

		helpers.assert_true(not any_exec_matches("find "),
			"the find/rm purge pipeline must NOT run synchronously during init_log_path")
		helpers.assert_true(#deferred >= 1,
			"the purge must be scheduled via hs.timer.doAfter")

		-- Driving the deferred callback must actually perform the purge.
		exec_log = {}
		for _, fn in ipairs(deferred) do pcall(fn) end
		helpers.assert_true(any_exec_matches("find "),
			"the deferred callback must run the find purge")

		hs.timer.doAfter = saved_doAfter
	end)

	helpers.it("exposes _purge_old_logs for direct invocation", function()
		helpers.assert_eq(type(Logger._purge_old_logs), "function")
	end)

	helpers.it("_purge_old_logs is a no-op on an empty path (fail-safe)", function()
		exec_log = {}
		Logger._purge_old_logs("", 14)
		helpers.assert_true(#exec_log == 0, "an empty log dir must not spawn any shell work")
	end)
end)

-- Restore the real modules so subsequent test files are unaffected.
package.loaded["adapters.shell_runner"] = _real_shell_loaded
package.loaded["lib.logger"]            = _real_logger_loaded
