--- tests/unit/lib/test_logger_subfile_daily_reset.lua

--- ==============================================================================
--- MODULE: Regression — topical sub-files must reset on the first write of a day
--- DESCRIPTION:
--- The topical logs (ErgoptiPlus_mlx.log, _llm.log, _karabiner.log, …) are
--- ephemeral by design: each is meant to hold only the current day's lines, so
--- triage means opening one small file rather than grepping a growing archive.
--- They grew without bound instead.
---
--- ROOT CAUSE ENCODED:
--- The reset was implemented as a pass inside _purge_old_logs, deleting any
--- sub-file whose mtime is not today. But the purge is deferred by
--- LOG_PURGE_DELAY_SEC (5 s) after boot, while the fan-out in _write_to_file
--- appends from the very first log line. By the time the purge runs, every
--- sub-file that received a line already has mtime == today, so the predicate is
--- false exactly for the files that needed resetting. The only sub-files it could
--- ever delete were the silent ones — the ones with nothing to reset. The test
--- is inverted with respect to its own intent.
---
--- WHY IT WAS SILENT:
--- Nothing fails. Logging keeps working and the file keeps growing; yesterday's
--- lines simply sit above today's with no marker between them, which reads as a
--- long session rather than as a reset that never happened.
---
--- The fix decides the io.open mode per sub-file per calendar date, evaluating
--- the mtime-is-today predicate BEFORE the logger touches the file — the only
--- moment at which mtime still answers "does this file hold only today?".
--- ==============================================================================

local helpers = require("tests.helpers")

local Logger = helpers.load_with_stubs("lib.logger")

-- Days of staleness stamped on the fake sub-file, so "mtime is not today" is
-- unambiguous regardless of the hour the suite runs at.
local STALE_DAYS      = 3
local SECONDS_PER_DAY = 86400

-- A line matching a built-in sub-file pattern, so the fan-out is guaranteed to
-- select at least one topical file. "[karabiner" is in SUB_LOG_NAMES_FALLBACK.
local ROUTED_LINE_TAG = "[karabiner]"





-- ===============================================
-- ===============================================
-- ======= 1/ Open Mode On The First Write =======
-- ===============================================
-- ===============================================

--- Captures the (path, mode) pairs the logger passes to io.open while `body` runs.
--- hs.fs.attributes reports every file as `stale_days` old, so the sub-file under
--- test looks like one carrying a previous day's lines.
--- @param stale_days number Age reported for every file.
--- @param body function Callback run with the stubs installed.
--- @return table Array of { path = string, mode = string }.
local function capture_opens(stale_days, body)
	local hs           = _G.hs
	local saved_attrs  = hs.fs.attributes
	local saved_open   = io.open
	local saved_level  = Logger.current_level
	local opens        = {}

	-- The suite runs at WARNING, which drops Logger.info before it ever reaches
	-- the fan-out. Lower the threshold so the routed line is actually written.
	Logger.set_level("DEBUG")

	hs.fs.attributes = function(_path)
		return { modification = os.time() - (stale_days * SECONDS_PER_DAY) }
	end

	io.open = function(path, mode)
		opens[#opens + 1] = { path = tostring(path), mode = tostring(mode) }
		-- Hand back a writable sink rather than touching the disk: the assertion
		-- is about the mode requested, not about the bytes landing anywhere.
		return {
			write = function() end,
			flush = function() end,
			close = function() end,
			read  = function() return nil end,
		}
	end

	local ok, err = pcall(body)

	io.open          = saved_open
	hs.fs.attributes = saved_attrs
	Logger.set_level(saved_level)

	if not ok then error(err, 0) end
	return opens
end

--- Returns the modes used for the topical sub-file among captured opens.
--- @param opens table Result of capture_opens.
--- @return table Array of mode strings, in order.
local function sub_file_modes(opens)
	local modes = {}
	for _, o in ipairs(opens) do
		if o.path:find("ErgoptiPlus_karabiner%.log$") then modes[#modes + 1] = o.mode end
	end
	return modes
end

helpers.describe("logger — topical sub-files reset on the first write of a new day", function()
	helpers.it("truncates a sub-file whose last write was a previous day", function()
		local opens = capture_opens(STALE_DAYS, function()
			Logger.init_log_path("/tmp/ergopti_subfile_reset/", 14)
			Logger.info("karabiner", ROUTED_LINE_TAG .. " first line of the day")
		end)

		local modes = sub_file_modes(opens)
		helpers.assert_true(#modes > 0,
			"the fan-out must have opened the karabiner sub-file — with no open captured "
			.. "this test would assert nothing")
		helpers.assert_eq(modes[1], "w",
			"the FIRST write of a calendar date must truncate a sub-file left over from an "
			.. "earlier day. Appending is what let the topical logs accumulate forever: the "
			.. "purge pass meant to reset them runs 5 s after boot, by which point this very "
			.. "append has already stamped the file with today's mtime, so the purge's "
			.. "\"mtime is not today\" test can never fire for an active sub-file")
	end)

	helpers.it("appends on every later write of the same day", function()
		local opens = capture_opens(STALE_DAYS, function()
			Logger.init_log_path("/tmp/ergopti_subfile_reset/", 14)
			Logger.info("karabiner", ROUTED_LINE_TAG .. " first line of the day")
			Logger.info("karabiner", ROUTED_LINE_TAG .. " second line of the day")
			Logger.info("karabiner", ROUTED_LINE_TAG .. " third line of the day")
		end)

		local modes = sub_file_modes(opens)
		helpers.assert_true(#modes >= 1,
			"at least one sub-file open must be captured for this assertion to mean anything")

		-- The invariant is "only the FIRST write of a calendar day may truncate",
		-- and it is asserted as such rather than as "one open per write". The
		-- fan-out now keeps its handles open — the same policy the main handle
		-- follows because DEBUG lines come off the keystroke path — so a same-day
		-- burst legitimately produces a single open. What must never appear is a
		-- SECOND truncating open, which would discard the day's earlier lines.
		local truncations = 0
		for _, m in ipairs(modes) do
			if m == "w" then truncations = truncations + 1 end
		end
		helpers.assert_true(truncations <= 1,
			"only the first write of a calendar day may truncate; a second 'w' throws away "
			.. "everything logged earlier that day")

		for i = 2, #modes do
			helpers.assert_eq(modes[i], "a", string.format(
				"write #%d of the same day must APPEND: truncating on every write would keep "
				.. "only the last line and destroy the day's history (G2)", i))
		end
	end)

	helpers.it("appends when the sub-file already carries today's lines", function()
		local opens = capture_opens(0, function()
			Logger.init_log_path("/tmp/ergopti_subfile_reset/", 14)
			Logger.info("karabiner", ROUTED_LINE_TAG .. " continuing today's file")
		end)

		local modes = sub_file_modes(opens)
		helpers.assert_true(#modes > 0, "the fan-out must have opened the karabiner sub-file")
		helpers.assert_eq(modes[1], "a",
			"a sub-file whose mtime is already today holds this same day's lines — a restart "
			.. "mid-day must not wipe what earlier runs logged")
	end)
end)
