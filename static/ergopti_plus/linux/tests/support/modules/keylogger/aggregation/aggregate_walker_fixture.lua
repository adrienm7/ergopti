--- tests/support/modules/keylogger/aggregation/aggregate_walker_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_aggregate_walker
--- DESCRIPTION:
--- Prelude shared by the test_aggregate_walker_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

local it = require("tests.support.metrics_preferences_fixture").it

local Fakes = helpers.load_module("tests.fakes")

local Walker = helpers.load_module("modules.keylogger.aggregate_walker")

local Timings = helpers.load_module("infra.timings")

local PAUSE_MS = Timings.ms("keylogger", "max_keystroke_delay_ms")

local SESSION_GAP_MS = Timings.ms("keylogger", "session_gap_ms")

--- One buffered keystroke.
--- @param char string
--- @param delay number|nil
--- @param source string|nil "hotstring", "llm", … for synthetic output.
--- @return table
local function key(char, delay, source)
	if source then
		return { char, delay or 0, { s = 1, st = source } }
	end
	return { char, delay or 0, { s = 0 } }
end

--- Types a string as ordinary keystrokes at a comfortable pace.
--- @param text string
--- @param delay number|nil
--- @return table
local function typed(text, delay)
	local out = {}
	for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		out[#out + 1] = key(char, delay or 120)
	end
	return out
end

--- The count a family holds for one token.
--- @param batch table
--- @param family string
--- @param token string
--- @return number
local function count_of(batch, family, token)
	local rows = batch.ngram[family] or {}
	local item = rows["2026-08-06\1app\1" .. token]
	return item and item.c or 0
end

return {
	helpers = helpers,
	it = it,
	Fakes = Fakes,
	Walker = Walker,
	Timings = Timings,
	PAUSE_MS = PAUSE_MS,
	SESSION_GAP_MS = SESSION_GAP_MS,
	key = key,
	typed = typed,
	count_of = count_of,
}
