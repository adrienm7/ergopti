--- tests/unit/lib/test_logger_dedup_errors_mirror.lua

--- ==============================================================================
--- MODULE: Regression — lib-logger-perf-002, the errors log hid the repeat count
--- DESCRIPTION:
--- Identical WARNING or ERROR lines are deduplicated: the first is written, the
--- repeats are swallowed, and closing the streak emits a "N identical lines
--- suppressed" summary. That worked in the unified daily log. The errors-only
--- log — the small file that exists so triage is one read rather than a grep —
--- received the first occurrence and nothing else.
---
--- So an error storm and a one-off error looked IDENTICAL in the file anyone
--- opens first. Nothing failed; the count was simply not there to be missed.
---
--- Fix: the suppression summary is mirrored into M.ERRORS_LOG_FILE whenever the
--- suppressed variant sits at WARNING or above.
---
--- WHY THIS TEST IS BEHAVIOURAL, AND WAS NOT.
--- It used to assert three things about the TEXT of _flush_dedup_summary: that
--- the body contained "variant.level >= M.LEVELS.WARNING", that it contained
--- "M.ERRORS_LOG_FILE", and that the second appeared before the counter reset.
--- All three hold for correct code — and all three also hold for code that writes
--- the wrong number, because a grep can see that a counter is read before it is
--- cleared but never that the value is right. The third assertion had already had
--- to be repaired once, when it sliced a fixed 1200 characters and started failing
--- on an invariant that was still perfectly satisfied.
---
--- It now asserts the property the bug actually violated: the errors-only log
--- carries the SAME summary as the unified log, character for character, with the
--- right count in it. Stronger than the scan it replaces, and indifferent to where
--- the code that produces it happens to live.
--- ==============================================================================

local helpers = require("tests.helpers")

local Logger = helpers.load_with_stubs("infra.logger")

-- Identical lines emitted after the first, inside the five-second window. Three,
-- so the expected summary reads "3" — a number that cannot be confused with the
-- count of lines actually emitted, nor with a stray 1.
local SUPPRESSED_COUNT = 3

-- Log directory for the capture. Nothing reaches the disk (io.open is replaced),
-- so this only has to be a stable absolute-looking path.
local LOG_DIR = "/tmp/ergopti_dedup_mirror/"




--- Runs `body` with io.open recording every write, and returns the reader.
--- @param body function Callback run with the recorder installed.
--- @return function A (path) → string reader over everything that path received.
local function capture(body)
	local hs          = _G.hs
	local saved_attrs = hs.fs and hs.fs.attributes or nil
	local saved_open  = io.open
	local saved_level = Logger.current_level
	local writes      = {}

	-- The suite runs at WARNING. ERROR clears that on its own, but the INFO case
	-- below does not, and a test should not depend on a harness default it can set.
	Logger.set_level("DEBUG")
	Logger.reset_dedup()

	if hs.fs then
		hs.fs.attributes = function(_path) return { modification = os.time() } end
	end
	io.open = function(path, _mode)
		local key = tostring(path)
		writes[key] = writes[key] or {}
		return {
			write = function(_self, chunk) writes[key][#writes[key] + 1] = tostring(chunk) end,
			flush = function() end,
			close = function() end,
			read  = function() return nil end,
		}
	end

	-- Re-pointing closes any handle a previous capture left cached, which would
	-- otherwise keep writing into that capture's recorder.
	local ok, err = pcall(function()
		Logger.init_log_path(LOG_DIR, 14)
		body()
	end)

	io.open = saved_open
	if hs.fs then hs.fs.attributes = saved_attrs end
	Logger.set_level(saved_level)
	Logger.reset_dedup()
	if not ok then error(err, 0) end

	return function(path)
		return writes[path] and table.concat(writes[path]) or ""
	end
end

--- Emits one line, three identical repeats, then a different line to close the
--- streak and force the summary out.
--- @param emit function Logger.error or Logger.info.
local function storm(emit)
	emit("storm_mod", "the recurring failure")
	for _ = 1, SUPPRESSED_COUNT do
		emit("storm_mod", "the recurring failure")
	end
	emit("storm_mod", "an unrelated failure")
end

--- Extracts the suppression summary line from a sink's contents.
--- @param blob string Everything one sink received.
--- @return string|nil The summary line, without its trailing newline.
local function summary_line(blob)
	for line in blob:gmatch("([^\n]+)") do
		if line:find("identical", 1, true) then return line end
	end
	return nil
end

helpers.describe("lib-logger-perf-002: the errors-only log must carry the repeat count", function()
	helpers.it("mirrors the suppression summary, identical to the unified one", function()
		local read = capture(function() storm(Logger.error) end)

		local from_unified = summary_line(read(Logger.UNIFIED_LOG_FILE))
		local from_errors  = summary_line(read(Logger.ERRORS_LOG_FILE))

		helpers.assert_true(from_unified ~= nil, string.format(
			"the unified log must carry a suppression summary — without one there is nothing to "
			.. "mirror and this test asserts nothing at all. Got:\n%s", read(Logger.UNIFIED_LOG_FILE)))

		helpers.assert_true(from_errors ~= nil, string.format(
			"the errors-only log must carry the suppression summary too. This is the bug: the "
			.. "file anyone opens first showed the first occurrence and stopped, so an error "
			.. "storm and a one-off error read identically. Got:\n%s", read(Logger.ERRORS_LOG_FILE)))

		helpers.assert_eq(from_errors, from_unified,
			"the mirrored summary must be the SAME line as the unified one. A mirror that "
			.. "re-renders is a second formatter, and the first thing a second formatter gets "
			.. "wrong is the number")
	end)

	helpers.it("reports the exact number of lines it swallowed", function()
		local read = capture(function() storm(Logger.error) end)
		local line = summary_line(read(Logger.ERRORS_LOG_FILE)) or ""

		-- Matched as "N identical", never as a bare "N". The line carries a
		-- timestamp, and a probe that corrupted the count to 0 still passed a bare
		-- digit search — because the run happened on 2026-08-03 and the date
		-- supplied the 3. An assertion that a calendar can satisfy is not one.
		local expected = string.format("%d identical", SUPPRESSED_COUNT)
		helpers.assert_true(line:find(expected, 1, true) ~= nil, string.format(
			"the summary must report \"%s\". The source scan this test replaced could see that "
			.. "the counter was read before it was cleared, but never that the value was right "
			.. "— and a summary reading 0 is worse than no summary, because it claims nothing "
			.. "was lost. Got: %s", expected, line))
	end)

	helpers.it("keeps a suppressed INFO streak out of the errors-only log", function()
		local read = capture(function() storm(Logger.info) end)

		helpers.assert_true(summary_line(read(Logger.UNIFIED_LOG_FILE)) ~= nil,
			"the INFO streak's summary must still reach the unified log — otherwise this case "
			.. "passes because nothing was suppressed at all, which is the shape of a vacuous "
			.. "absence assertion")

		helpers.assert_true(summary_line(read(Logger.ERRORS_LOG_FILE)) == nil,
			"an INFO suppression summary must NOT reach the errors-only log. The summary "
			.. "inherits the variant of the lines it stands for, so a mirror keyed on anything "
			.. "else refills the triage file with exactly the routine noise it exists to exclude")
	end)
end)
