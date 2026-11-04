--- tests/unit/ui/metrics/typing/test_ngram_history_merge_paced.lua

--- ==============================================================================
--- MODULE: Paced N-Gram History Extension
--- DESCRIPTION:
--- Extending the cached all-time n-gram history copies it and adds the new
--- days. Both merges ran without a pause inside the paced range job, so one
--- slice held the main thread 458 ms (field report 2026-11-03 01:04, "N-gram
--- history extended"). The merge now pauses at every token of a paced job.
--- ==============================================================================

local helpers = require("tests.helpers")

local TOKENS = 50

--- Builds an n-gram dict whose `c` bucket holds `count` tokens.
--- @param count integer Number of tokens.
--- @return table dict
local function dict_of(count)
	local out = { c = {} }
	for index = 1, count do
		out.c["t" .. index] = { c = 1, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
	end
	return out
end

helpers.describe("n-gram history merge yields to the run loop (ngram-merge-paced)", function()
	helpers.it("pauses at every merged token when given a pacer", function()
		local Reader = helpers.load_with_stubs("modules.keystats.sqlite_reader")
		local pauses = 0
		local pacer = { pause = function() pauses = pauses + 1 end }
		local merged = Reader.merge_ngrams({}, dict_of(TOKENS), pacer)
		helpers.assert_eq(pauses, TOKENS, "every token is a safe point of the paced job")
		helpers.assert_eq(merged.c.t1.c, 1)
		helpers.assert_eq(Reader.merge_ngrams(merged, dict_of(TOKENS)).c.t1.c, 2, "a merge without a pacer still adds")
	end)

	helpers.it("passes the job's pacer to both merges of a history extension", function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local Real = helpers.load_with_stubs("modules.keystats.sqlite_reader")
		local projection = helpers.load_with_stubs("ui.metrics_typing.projection")
		projection.reset()
		local pacer = { pause = function() end }
		local merge_pacers = {}
		local reader = {
			next_day = Real.next_day,
			split_bounds = Real.split_bounds,
			fingerprint = function() return "unchanged" end,
			read_today_split = function() return {} end,
			read_ngrams = function() return dict_of(TOKENS), true end,
		}
		function reader.merge_ngrams(into, from, given)
			merge_pacers[#merge_pacers + 1] = given or false
			return Real.merge_ngrams(into, from, given)
		end
		projection.session(reader, "/db.sqlite", "2026-10-20", pacer).range("2026-10-01", nil, nil)
		helpers.assert_eq(#merge_pacers, 0, "a first projection reads without merging")
		projection.session(reader, "/db.sqlite", "2026-10-21", pacer).range("2026-10-01", nil, nil)
		helpers.assert_eq(#merge_pacers, 2, "the extension copies the history, then adds the new day")
		helpers.assert_true(rawequal(merge_pacers[1], pacer), "the history copy must pause")
		helpers.assert_true(rawequal(merge_pacers[2], pacer), "the new day's merge must pause")
	end)
end)
