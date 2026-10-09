--- tests/unit/modules/keylogger/test_kc_bridge_discards_backlog.lua

--- ==============================================================================
--- MODULE: Regression — the KE bridge must not replay its off-window backlog
--- DESCRIPTION:
--- A bridge restart must never replay bytes written while no trusted drain
--- cursor existed, stamped with the current time and focused application.
---
--- ROOT CAUSE ENCODED:
--- The normal Metrics OFF path now deliberately leaves the KC watcher and poll
--- timer alive, so the cursor advances while persistence is denied; the
--- behavioural proof lives in test_kc_bridge_offset_advances_while_disabled.lua.
--- This test pins the independent recovery backstop: if producer ownership or
--- cursor trust was lost, M.start() must call the single EOF-resync helper before
--- it can re-arm or reuse the drain producers.
---
--- The helper owns the open/seek/close proof and publishes both the EOF offset
--- and the cursor-trusted bit. Keeping those mutations in one function prevents
--- init() and recovery start() from drifting apart.
---
--- Discarding is the only correct choice. The user deliberately switched recording
--- off, and the real timestamps and focused-app context of those keys are gone, so
--- replaying them cannot produce true data — only plausible-looking false data,
--- which is worse.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ The Restart Skips The Gap =========
-- ==============================================
-- ==============================================

helpers.describe("kc_bridge discards keystrokes appended while it was stopped", function()
	helpers.it("re-syncs the file offset to EOF on start()", function()
		-- Selected by a declaration unique to modules/keylogger/kc_bridge.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function ke_name_to_num")
		helpers.assert_true(src ~= nil, "modules/keylogger/kc_bridge.lua source must be locatable")
		if not src then return end

		local start_at = src:find("function M%.start%(%)")
		helpers.assert_true(start_at ~= nil, "M.start must be locatable")

		-- Bound the slice to M.start's body so init()'s call cannot satisfy this.
		local body_end = src:find("\n%-%-%-", start_at + 10) or #src
		local body = src:sub(start_at, body_end)

		helpers.assert_true(
			body:find("if not _watchers_active or not _cursor_trusted then", 1, true) ~= nil,
			"M.start() must refuse the fast path whenever producer ownership or cursor trust was lost")
		helpers.assert_true(body:find("resync_cursor_to_eof()", 1, true) ~= nil,
			"M.start() must prove a fresh EOF before recovering an inactive or untrusted bridge")

		local helper_at = src:find("local function resync_cursor_to_eof()", 1, true)
		helpers.assert_true(helper_at ~= nil, "the EOF resync helper must be locatable")
		local helper_end = src:find("\nend\n", helper_at) or #src
		local helper = src:sub(helper_at, helper_end)
		helpers.assert_true(helper:find('handle:seek("end")', 1, true) ~= nil,
			"the shared recovery helper must seek the physical ledger to EOF")
		helpers.assert_true(helper:find("_file_offset = eof_or_err", 1, true) ~= nil,
			"the proven EOF must be published as the next drain offset")
		helpers.assert_true(helper:find("_cursor_trusted = true", 1, true) ~= nil,
			"cursor trust may open only after the EOF proof commits")
	end)

	helpers.it("still reports how much was skipped", function()
		-- Silently dropping data is its own problem: the skip must be visible in the
		-- log so an unexpected gap in the metrics is explainable afterwards.
		-- Selected by a declaration unique to modules/keylogger/kc_bridge.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function ke_name_to_num")
		helpers.assert_true(src ~= nil, "modules/keylogger/kc_bridge.lua source must be locatable")
		if not src then return end

		helpers.assert_true(src:find("Skipping ", 1, true) ~= nil,
			"the number of skipped bytes must be logged — a silent discard leaves an "
			.. "unexplained hole in the metrics")
	end)
end)
