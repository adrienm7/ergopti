--- tests/unit/lib/test_logger_rollover_purge_integrity.lua

--- ==============================================================================
--- MODULE: Logger rollover purge integrity regression
--- DESCRIPTION:
--- Proves that a long-running Hammerspoon process preserves the logger retention
--- contract after midnight. The first successful write of a new calendar day
--- must close the previous handle, route both sinks to the new date, and commit
--- exactly one deferred purge without requiring a reload.
---
--- ROOT CAUSES ENCODED:
--- 1. init_log_path() used to be the only purge scheduler, so daily files rotated
---    correctly while retention silently stopped until the next process restart.
--- 2. A bare pcall inside the timer callback hid every unexpected purge failure
---    from the file logger.
--- 3. _purge_old_logs() counted os.remove() attempts instead of successful
---    removals, reporting deleted files that remained on disk.
--- 4. A returned hs.timer handle was checked but not retained; Hammerspoon's
---    userdata stops the native timer from __gc, so collection could cancel the
---    only purge callback before delivery.
---
--- The test replaces the clock, file handles, timer constructor, directory walk,
--- and removal operation with faithful in-memory ports. No host file is touched.
--- ==============================================================================

local helpers = require("tests.helpers")

local Logger = helpers.load_with_stubs("infra.logger")

local DAY_A = "2099-01-01"
local DAY_B = "2099-01-02"
local RETENTION_DAYS = 14
local TEST_CONFIG_DIR = "/virtual/logger-rollover/"

--- Returns true when any captured line contains every requested literal token.
--- @param lines table Array of rendered logger lines.
--- @param ... string Literal tokens that must all occur in one line.
--- @return boolean matched Whether a matching line exists.
local function any_line_contains(lines, ...)
	local tokens = { ... }
	for _, line in ipairs(lines) do
		local matched = true
		for _, token in ipairs(tokens) do
			if not line:find(token, 1, true) then
				matched = false
				break
			end
		end
		if matched then return true end
	end
	return false
end

--- Concatenates every byte written through handles opened for one path.
--- @param handles_by_path table Map from path to an array of fake handles.
--- @param path string Path whose writes should be collected.
--- @return string bytes Concatenated writes in open order.
local function bytes_for(handles_by_path, path)
	local chunks = {}
	for _, handle in ipairs(handles_by_path[path] or {}) do
		for _, chunk in ipairs(handle.writes) do chunks[#chunks + 1] = chunk end
	end
	return table.concat(chunks)
end

helpers.describe("logger rollover purge integrity", function()
	helpers.it("rollover commits one purge and reports timer and removal failures", function()
		local hs_ref = _G.hs
		local saved_date = os.date
		local saved_open = io.open
		local saved_remove = os.remove
		local saved_dir = hs_ref.fs.dir
		local saved_attrs = hs_ref.fs.attributes
		local saved_mkdir = hs_ref.fs.mkdir
		local saved_do_after = hs_ref.timer.doAfter
		local saved_purge = Logger._purge_old_logs
		local saved_level = Logger.current_level

		local current_day = DAY_A
		local timer_mode = "commit"
		local directory_entries = {}
		local failed_remove_path = nil
		local handles_by_path = {}
		local timers = {}
		local timer_count = 0
		local remove_calls = {}
		local captured = {}

		os.date = function(format, timestamp)
			if format == "%Y-%m-%d" and timestamp == nil then return current_day end
			return saved_date(format, timestamp)
		end

		io.open = function(path, mode)
			local handle = {
				path = tostring(path),
				mode = tostring(mode),
				writes = {},
				closed = false,
			}
			function handle:write(chunk)
				self.writes[#self.writes + 1] = tostring(chunk)
				return true
			end
			function handle:flush() return true end
			function handle:close()
				self.closed = true
				return true
			end
			handles_by_path[handle.path] = handles_by_path[handle.path] or {}
			handles_by_path[handle.path][#handles_by_path[handle.path] + 1] = handle
			return handle
		end

		hs_ref.fs.mkdir = function(_path) return true end
		hs_ref.fs.attributes = function(_path) return nil end
		hs_ref.fs.dir = function(_path)
			local index = 0
			local directory = setmetatable({}, { __name = "hs.fs.dir directory object" })
			return function(state)
				if state ~= directory then error("directory metatable expected", 2) end
				index = index + 1
				return directory_entries[index]
			end, directory
		end

		os.remove = function(path)
			path = tostring(path)
			remove_calls[#remove_calls + 1] = path
			if path == failed_remove_path then return nil, "permission denied", 13 end
			return true
		end

		hs_ref.timer.doAfter = function(delay, callback)
			if timer_mode == "throw" then error("timer constructor failure") end
			if timer_mode == "reject" then return nil end
			local timer = { delay = delay, callback = callback }
			timer_count = timer_count + 1
			timers[timer_count] = timer
			return timer
		end

		Logger.reset_dedup()
		Logger.set_level(Logger.LEVELS.DEBUG)
		Logger.set_sink(function(line) captured[#captured + 1] = line end)

		local ok, err = xpcall(function()
			Logger.init_log_path(TEST_CONFIG_DIR, RETENTION_DAYS)
			helpers.assert_eq(timer_count, 1,
				"init_log_path must commit one deferred boot purge")
			local boot_timer_weak = setmetatable({ timers[1] }, { __mode = "v" })
			local boot_callback = timers[1].callback
			timers[1] = nil
			collectgarbage("collect")
			helpers.assert_not_nil(boot_timer_weak[1],
				"the logger must retain the hs.timer handle until purge delivery; "
					.. "Hammerspoon stops an unreferenced timer from __gc")

			-- Empty boot housekeeping isolates the later timer as the rollover purge
			boot_callback()
			boot_callback = nil
			collectgarbage("collect")
			helpers.assert_eq(boot_timer_weak[1], nil,
				"a delivered one-shot purge timer must be released rather than leaked")
			Logger.info("logger_rollover_test", "Day A marker.")

			local day_a_path = Logger.UNIFIED_LOG_FILE
			local day_a_handle = (handles_by_path[day_a_path] or {})[1]
			helpers.assert_true(day_a_handle ~= nil,
				"the day-A write must open the day-A unified file")

			current_day = DAY_B
			Logger.warn("logger_rollover_test", "Day B first marker.")

			local day_b_path = TEST_CONFIG_DIR .. "hammerspoon/logs/ErgoptiPlus_" .. DAY_B .. ".log"
			local day_b_errors_path = TEST_CONFIG_DIR
				.. "hammerspoon/logs/ErgoptiPlus_errors_" .. DAY_B .. ".log"
			helpers.assert_true(day_a_handle.closed,
				"the first day-B write must close the day-A unified handle")
			helpers.assert_true(bytes_for(handles_by_path, day_a_path):find("Day B", 1, true) == nil,
				"no day-B bytes may be appended to the day-A file")
			helpers.assert_true(bytes_for(handles_by_path, day_b_path):find("Day B first marker", 1, true) ~= nil,
				"the unified day-B file must receive the first post-midnight line")
			helpers.assert_true(bytes_for(handles_by_path, day_b_errors_path):find("Day B first marker", 1, true) ~= nil,
				"the errors-only day-B file must receive the post-midnight warning")
			helpers.assert_eq(timer_count, 2,
				"the first successful day-B write must commit one deferred rollover purge")

			Logger.info("logger_rollover_test", "Day B second marker.")
			helpers.assert_eq(timer_count, 2,
				"later writes on the same day must not schedule another purge")

			directory_entries = {
				"ErgoptiPlus_2000-01-01.log",
				"ErgoptiPlus_errors_2000-01-01.log",
			}
			remove_calls = {}
			timers[2].callback()
			helpers.assert_eq(#remove_calls, 2,
				"the rollover purge must process stale unified and errors-only logs")
			helpers.assert_true(remove_calls[1]:find("ErgoptiPlus_2000-01-01.log", 1, true) ~= nil,
				"the rollover purge must remove the stale unified log")
			helpers.assert_true(remove_calls[2]:find("ErgoptiPlus_errors_2000-01-01.log", 1, true) ~= nil,
				"the rollover purge must remove the stale errors-only log")

			-- A failed remove is a warning, never a fabricated successful count
			directory_entries = { "ErgoptiPlus_2000-01-01.log" }
			failed_remove_path = TEST_CONFIG_DIR
				.. "hammerspoon/logs/ErgoptiPlus_2000-01-01.log"
			captured = {}
			Logger._purge_old_logs(TEST_CONFIG_DIR .. "hammerspoon/logs/", RETENTION_DAYS)
			helpers.assert_true(any_line_contains(captured, "[WARNING]", "permission denied", failed_remove_path),
				"os.remove returning nil must log the path and failure reason")
			helpers.assert_true(not any_line_contains(captured, "Old-log purge removed 1 stale file(s)."),
				"a refused removal must not be counted or reported as removed")

			-- An exception raised after the timer fires must reach the file logger
			failed_remove_path = nil
			directory_entries = {}
			captured = {}
			Logger.init_log_path(TEST_CONFIG_DIR .. "async/", RETENTION_DAYS)
			local async_timer = timers[timer_count]
			Logger._purge_old_logs = function() error("synthetic async purge failure") end
			async_timer.callback()
			Logger._purge_old_logs = saved_purge
			helpers.assert_true(any_line_contains(
				captured, "[ERROR]", "synthetic async purge failure"),
				"a purge callback exception must be logged instead of swallowed by pcall")

			-- pcall success alone is not a committed timer: nil means no callback exists
			captured = {}
			timer_mode = "reject"
			Logger.init_log_path(TEST_CONFIG_DIR .. "reject/", RETENTION_DAYS)
			helpers.assert_true(any_line_contains(captured, "[ERROR]", "purge", "scheduled"),
				"doAfter returning nil must be reported as an uncommitted purge")

			captured = {}
			timer_mode = "throw"
			local constructor_ok = pcall(
				Logger.init_log_path, TEST_CONFIG_DIR .. "throw/", RETENTION_DAYS)
			helpers.assert_true(constructor_ok,
				"a timer-constructor exception must not escape init_log_path")
			helpers.assert_true(any_line_contains(captured, "[ERROR]", "timer constructor failure"),
				"a timer-constructor exception must be recorded in the file logger")
		end, debug.traceback)

		Logger._purge_old_logs = saved_purge
		Logger.set_sink(nil)
		Logger.set_level(saved_level)
		os.date = saved_date
		io.open = saved_open
		os.remove = saved_remove
		hs_ref.fs.dir = saved_dir
		hs_ref.fs.attributes = saved_attrs
		hs_ref.fs.mkdir = saved_mkdir
		hs_ref.timer.doAfter = saved_do_after

		if not ok then error(err, 0) end
	end)
end)
