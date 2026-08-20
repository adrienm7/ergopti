--- tests/unit/lib/test_logger_deferred_purge.lua

--- ==============================================================================
--- MODULE: Logger — Old-Log Purge Spawns Nothing (perf + correctness regression)
--- DESCRIPTION:
--- Locks down two properties of M._purge_old_logs():
---   1. It spawns ZERO subprocesses. It is reached from a deferred hs.timer, and
---      ShellRunner.exec is `pcall(hs.execute, cmd)` — fully synchronous. The old
---      implementation ran a `find | while read … date … rm` pipeline forking
---      basename + sed + two `date` calls PER log file, plus a `stat` per
---      sub-file, all on the MAIN THREAD. Deferring it by 5 s moved that off the
---      boot path and straight into the window where the keystroke event tap is
---      armed and the user is typing — strictly worse than at boot, where it was
---      at least invisible. Only "no subprocess at all" actually fixes it.
---   2. It purges the errors-only sink. ErgoptiPlus_errors_YYYY-MM-DD.log was
---      NEVER deleted: `basename … | sed 's/ErgoptiPlus_//'` yields
---      "errors_2026-06-01", `date -j -f %Y-%m-%d` cannot parse that, the `&&`
---      short-circuited and no `rm` ever ran. The file grew without bound,
---      contradicting the module header's documented retention policy.
---
--- ROOT CAUSE ENCODED: `#exec_log == 0` is the load-bearing assertion. The
--- previous version of this file only asserted that firing the deferred callback
--- ran `find` — which is precisely why the blocking shell work was invisible to
--- CI: the test demanded the very thing that made the driver stutter.
---
--- FEATURES & RATIONALE:
--- 1. ShellRunner stub: records every exec() command, so "no subprocess" is an
---    assertion about observed behaviour, not about source text. Installed BEFORE
---    requiring the logger so its lazy require resolves to the stub.
--- 2. Filesystem stub: a hand-rolled hs.fs.dir iterator (faithful to the real
---    two-return-value contract) plus a captured os.remove, so the exact set of
---    deleted paths is observable without touching the real filesystem.
--- 3. Full restore: package.loaded entries, hs.timer.doAfter, hs.fs.* and
---    os.remove are all restored so no stub leaks into later test files.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Stub the shell adapter and reload the logger fresh so init_log_path picks it up.
local _real_logger_loaded = package.loaded["infra.logger"]
local _real_shell_loaded  = package.loaded["adapters.shell_runner"]

local exec_log = {}
package.loaded["adapters.shell_runner"] = {
	exec = function(cmd) exec_log[#exec_log + 1] = tostring(cmd); return "" end,
}
package.loaded["infra.logger"] = nil
local Logger = require("infra.logger")

-- Age (days) stamped on the fake topical sub-file so the ephemeral pass must drop it.
local STALE_SUB_FILE_AGE_DAYS = 3

-- Seconds per day — mirrors the logger's own retention unit.
local SECONDS_PER_DAY = 86400

-- Retention window passed to every purge call in this file.
local RETENTION_DAYS = 14

local TEST_LOG_DIR = "/tmp/ergopti_test_logs_purge/"

--- True when any recorded exec command matches a Lua pattern.
local function any_exec_matches(pat)
	for _, c in ipairs(exec_log) do
		if c:find(pat) then return true end
	end
	return false
end

--- True when `list` contains a path ending in `name`.
local function contains_name(list, name)
	for _, p in ipairs(list) do
		if p:find(name, 1, true) then return true end
	end
	return false
end

--- Runs `body` with hs.fs.dir / hs.fs.attributes / os.remove replaced by capturing
--- stubs, then restores every one of them.
---
--- The directory iterator mirrors real Hammerspoon: hs.fs.dir returns BOTH an
--- iterator and a directory object, and the iterator rejects any other state — so
--- production code that drops the second return value fails here exactly as it
--- would against the real API.
--- @param entries table Array of entry names the fake directory should yield.
--- @param body function Callback receiving the list of removed paths.
local function with_fake_log_dir(entries, body)
	local hs            = _G.hs
	local saved_dir     = hs.fs.dir
	local saved_attrs   = hs.fs.attributes
	local saved_remove  = os.remove

	hs.fs.dir = function(_path)
		local index      = 0
		local dir_object = setmetatable({}, { __name = "hs.fs.dir directory object" })
		return function(state)
			if state ~= dir_object then
				error("directory metatable expected", 2)
			end
			index = index + 1
			return entries[index]
		end, dir_object
	end
	-- Every sub-file reports a modification date several days in the past, so the
	-- ephemeral (today-only) pass must remove it.
	hs.fs.attributes = function(_path)
		return { modification = os.time() - (STALE_SUB_FILE_AGE_DAYS * SECONDS_PER_DAY) }
	end

	local removed = {}
	os.remove = function(path) removed[#removed + 1] = tostring(path) ; return true end

	local ok, err = pcall(body, removed)

	os.remove        = saved_remove
	hs.fs.dir        = saved_dir
	hs.fs.attributes = saved_attrs

	if not ok then error(err, 0) end
end

helpers.describe("logger — old-log purge is deferred AND spawns no subprocess", function()
	helpers.it("init_log_path defers the purge, and the deferred callback purges without forking", function()
		local hs = _G.hs
		local saved_doAfter = hs.timer.doAfter
		local deferred = {}
		-- Record the scheduled callback WITHOUT firing it.
		hs.timer.doAfter = function(_delay, fn) deferred[#deferred + 1] = fn end

		exec_log = {}
		Logger.init_log_path("/tmp/ergopti_test_logs_deferred/", RETENTION_DAYS)

		helpers.assert_true(not any_exec_matches("find "),
			"the purge must NOT run synchronously during init_log_path")
		helpers.assert_true(#deferred >= 1,
			"the purge must be scheduled via hs.timer.doAfter")

		hs.timer.doAfter = saved_doAfter

		-- Driving the deferred callback must actually perform the purge — and must
		-- do so without issuing a single shell command.
		with_fake_log_dir({ ".", "..", "ErgoptiPlus_2000-01-01.log" }, function(removed)
			exec_log = {}
			for _, fn in ipairs(deferred) do pcall(fn) end

			helpers.assert_true(contains_name(removed, "ErgoptiPlus_2000-01-01.log"),
				"the deferred callback must actually delete a stale daily log")
			helpers.assert_true(#exec_log == 0,
				"the deferred purge must spawn ZERO subprocesses — ShellRunner.exec is synchronous "
				.. "and it runs while the event tap is armed and the user is typing")
		end)
	end)

	helpers.it("exposes _purge_old_logs for direct invocation", function()
		helpers.assert_eq(type(Logger._purge_old_logs), "function")
	end)

	helpers.it("_purge_old_logs is a no-op on an empty path (fail-safe)", function()
		exec_log = {}
		Logger._purge_old_logs("", RETENTION_DAYS)
		helpers.assert_true(#exec_log == 0, "an empty log dir must not spawn any shell work")
	end)

	helpers.it("purges stale daily logs and the errors sink without spawning a subprocess", function()
		local today = os.date("%Y-%m-%d")
		local entries = {
			".", "..",
			"ErgoptiPlus_2000-01-01.log",
			"ErgoptiPlus_errors_2000-01-01.log",
			"ErgoptiPlus_llm.log",
			"ErgoptiPlus_" .. today .. ".log",
			"ErgoptiPlus_errors_" .. today .. ".log",
		}

		with_fake_log_dir(entries, function(removed)
			exec_log = {}
			Logger._purge_old_logs(TEST_LOG_DIR, RETENTION_DAYS)

			-- THE load-bearing assertion: the purge runs on the main thread, so any
			-- subprocess it forks is a stall the user feels mid-keystroke.
			helpers.assert_true(#exec_log == 0,
				"_purge_old_logs must spawn ZERO subprocesses — ShellRunner.exec blocks the main thread")

			helpers.assert_true(contains_name(removed, "ErgoptiPlus_errors_2000-01-01.log"),
				"the errors-only sink MUST be purged — the old shell pipeline could never match it, "
				.. "so ErgoptiPlus_errors_*.log grew without bound")
			helpers.assert_true(contains_name(removed, "ErgoptiPlus_2000-01-01.log"),
				"a stale main daily log must still be purged")
			helpers.assert_true(contains_name(removed, "ErgoptiPlus_llm.log"),
				"a topical sub-file whose mtime is not today must be purged (they are ephemeral)")

			helpers.assert_true(not contains_name(removed, "ErgoptiPlus_" .. today .. ".log"),
				"today's main log must NEVER be purged — it is the file being written to")
			helpers.assert_true(not contains_name(removed, "ErgoptiPlus_errors_" .. today .. ".log"),
				"today's errors sink must NEVER be purged")
		end)
	end)

	helpers.it("degrades with a warning instead of throwing when the filesystem port is missing", function()
		local hs = _G.hs
		local saved_fs = hs.fs
		hs.fs = nil

		local captured = {}
		Logger.set_sink(function(line) captured[#captured + 1] = line end)

		exec_log = {}
		local ok, purge_err = pcall(Logger._purge_old_logs, TEST_LOG_DIR, RETENTION_DAYS)

		Logger.set_sink(nil)
		hs.fs = saved_fs

		helpers.assert_nil(purge_err, "and must report none: " .. tostring(purge_err))
		helpers.assert_true(ok, "a missing filesystem port must degrade, not throw")
		helpers.assert_true(#exec_log == 0, "the degraded path must not fall back to shelling out")

		local warned = false
		for _, line in ipairs(captured) do
			if line:find("[WARNING]", 1, true) and line:find("purge skipped", 1, true) then
				warned = true
				break
			end
		end
		helpers.assert_true(warned, "the skipped purge must be logged, never swallowed silently")
	end)
end)

-- Restore the real modules so subsequent test files are unaffected.
package.loaded["adapters.shell_runner"] = _real_shell_loaded
package.loaded["infra.logger"]            = _real_logger_loaded
