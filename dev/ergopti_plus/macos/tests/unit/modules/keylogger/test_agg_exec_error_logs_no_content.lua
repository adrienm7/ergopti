--- tests/unit/modules/keylogger/test_agg_exec_error_logs_no_content.lua

--- ==============================================================================
--- MODULE: Regression — a failed aggregate write must not log user content
--- DESCRIPTION:
--- Sql.flush()'s exec() helper logged the first 200 characters of the failing
--- statement. Aggregate statements are BUILT from user content: n-gram tokens go
--- through sq(token) and window titles through sq(row.title), interpolated
--- straight into the SQL. So a locked or corrupt database turned every failed
--- write into a 14-day log line containing what the user typed and the titles of
--- the windows they typed it in.
---
--- ROOT CAUSE ENCODED:
--- A diagnostic written for developer convenience without classifying its
--- payload. Everything else in this subsystem is deliberate about that —
--- notify_synthetic logs a source type and counts, the context tracker logs only
--- an app name, the expander withholds a private trigger and replacement — which
--- is what made this one call site an outlier rather than the norm.
---
--- The fix derives the target table from the statement instead of threading a
--- name through nineteen call sites, so the diagnostic can only ever emit a bare
--- SQL identifier. This test pins the GUARANTEE (no user content in the log),
--- not that mechanism: any future rewrite is free to reach it differently.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Sentinels chosen so a substring match cannot collide with SQL keywords, table
-- names, or the simulated driver message.
local SECRET_TOKEN = "ZZSECRETTOKENZZ"
local SECRET_TITLE = "ZZSECRETWINDOWTITLEZZ"




-- =====================================
-- =====================================
-- ======= 1/ Module Loading ===========
-- =====================================
-- =====================================

local error_calls = {}

package.loaded["lib.logger"] = {
	debug   = function() end,
	info    = function() end,
	warn    = function() end,
	trace   = function() end,
	done    = function() end,
	start   = function() end,
	success = function() end,
	error   = function(_log, fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		table.insert(error_calls, ok and line or tostring(fmt))
	end,
}

package.loaded["modules.keylogger.export"] = {
	get_native_app_category = function() return "Development" end,
	init                    = function() end,
}

-- Every statement fails, so every exec() reaches the diagnostic under test.
local _db = {
	exec   = function() return 1 end,          -- SQLITE_ERROR
	errmsg = function() return "simulated failure" end,
}

package.loaded["modules.keylogger.sqlite_writer"] = {
	get_db = function() return _db end,
	init   = function() end,
}

local Sql  = helpers.load_with_stubs("modules.keylogger.aggregator.sql")
local S    = require("modules.keylogger.aggregator.state")
local Core = require("modules.keylogger.aggregator.core")




-- ==========================================================
-- ==========================================================
-- ======= 2/ No user content reaches the error log =========
-- ==========================================================
-- ==========================================================

helpers.describe("aggregator exec failure: the log carries no typed text and no window title", function()

	helpers.it("logs the target table and the driver message, never the statement", function()
		error_calls = {}
		S.initialized = true
		S.device_id   = "dev-privacy"
		Core.reset_batch()

		-- An n-gram row whose token IS the user's typed text.
		S.agg_batch.ngram["ngram_2"] = {
			["2024-03-03\1TestApp\1" .. SECRET_TOKEN] = { c = 1, td = 0, cd = 0, e = 0, esrc = {} },
		}
		-- A titles row whose title IS a window title.
		S.agg_batch.titles["2024-03-03\1TestApp\1" .. SECRET_TITLE] = {
			date = "2024-03-03", app = "TestApp", title = SECRET_TITLE, c = 1, ms = 0,
		}

		Sql.flush()

		helpers.assert_true(#error_calls > 0,
			"every statement was made to fail, so the failure diagnostic must have run at least once — "
			.. "otherwise this test would pass vacuously against any implementation")

		for _, line in ipairs(error_calls) do
			helpers.assert_true(line:find(SECRET_TOKEN, 1, true) == nil,
				"a failed aggregate write must not put the typed n-gram token in the 14-day log; got: " .. line)
			helpers.assert_true(line:find(SECRET_TITLE, 1, true) == nil,
				"a failed aggregate write must not put the window title in the 14-day log; got: " .. line)
		end
	end)

	helpers.it("still says which table failed, so the diagnostic stays useful", function()
		error_calls = {}
		S.initialized = true
		S.device_id   = "dev-privacy-2"
		Core.reset_batch()
		Core.bump_app_day("2024-04-04", "TestApp", "chars", 7)

		Sql.flush()

		local mentions_table = false
		for _, line in ipairs(error_calls) do
			if line:find("agg_app_day", 1, true) then mentions_table = true end
		end
		helpers.assert_true(mentions_table,
			"redacting the statement must not reduce the diagnostic to 'something failed' — "
			.. "the target table is a code-side identifier and is safe to name")
	end)

end)
