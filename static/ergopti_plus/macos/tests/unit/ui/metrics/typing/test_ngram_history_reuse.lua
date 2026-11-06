--- tests/unit/ui/metrics/typing/test_ngram_history_reuse.lua

--- ==============================================================================
--- MODULE: Unchanged N-Gram History Is Not Resent
--- DESCRIPTION:
--- Each live update made the dashboard request its range again, and the
--- host resent the whole all-time history every time: the delivery held the
--- main thread about 250 ms and grew the Lua heap by 73 MB each minute (field
--- report 2026-11-03, paced_job.lua:121 after "range projection completed").
--- A cached history now carries a serial; a request that names it gets
--- `historical_reused` instead of the history (ngram-history-reuse).
--- ==============================================================================

local helpers = require("tests.helpers")

local Json = require("json")

local TOKENS = 400

--- Builds an n-gram dict whose `c` bucket holds TOKENS tokens counted `count`.
--- @param count integer Count of each token.
--- @return table dict
local function dict_of(count)
	local out = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
	for index = 1, TOKENS do
		out.c["t" .. index] = { c = count, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
	end
	return out
end

--- Loads a fresh projection over a fake reader.
--- @return table projection, table reader, table world
local function fixture()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local Real = helpers.load_with_stubs("modules.keystats.sqlite_reader")
	local projection = helpers.load_with_stubs("ui.metrics_typing.projection")
	projection.reset()
	local world = { complete = true }
	local reader = {
		next_day = Real.next_day,
		split_bounds = Real.split_bounds,
		merge_ngrams = Real.merge_ngrams,
		history_fingerprint_exact = true, -- Controlled fixture with immutable historical rows.
			fingerprint = function() return "unchanged" end,
		read_today_split = function() return {}, true end,
		read_ngrams = function() return dict_of(1), world.complete end,
	}
	return projection, reader, world
end

--- Projects one open-ended range on `today` for a page holding `held`.
--- @return table decoded, string raw
local function range(projection, reader, today, held)
	local raw = projection.session(reader, "/db.sqlite", today, { pause = function() end })
		.range("2026-10-01", nil, nil, held)
	return Json.decode(raw), raw
end

helpers.describe("typing range omits a history the page holds (ngram-history-reuse)", function()
	helpers.it("names a cached history and omits it when the request names it back", function()
		local projection, reader = fixture()
		local first, first_raw = range(projection, reader, "2026-10-20", nil)
		helpers.assert_eq(type(first.historical), "table", "a page that holds nothing receives the history")
		helpers.assert_eq(type(first.historical_serial), "number")
		local again, again_raw = range(projection, reader, "2026-10-20", first.historical_serial)
		helpers.assert_eq(again.historical_reused, true)
		helpers.assert_eq(again.historical_serial, first.historical_serial)
		helpers.assert_nil(again.historical, "the unchanged history must not be resent")
		helpers.assert_true(#again_raw * 20 < #first_raw, "the reply shrinks to the live slice")
	end)

	helpers.it("resends the history for an unknown serial", function()
		local projection, reader = fixture()
		local first = range(projection, reader, "2026-10-20", nil)
		local other = range(projection, reader, "2026-10-20", first.historical_serial + 1)
		helpers.assert_eq(type(other.historical), "table")
		helpers.assert_nil(other.historical_reused)
	end)

	helpers.it("gives an extended or reset history a new serial", function()
		local projection, reader = fixture()
		local first = range(projection, reader, "2026-10-20", nil)
		local extended = range(projection, reader, "2026-10-21", first.historical_serial)
		helpers.assert_eq(type(extended.historical), "table", "a new day changes the history")
		helpers.assert_true(extended.historical_serial ~= first.historical_serial)
		projection.reset()
		local rebuilt = range(projection, reader, "2026-10-21", extended.historical_serial)
		helpers.assert_eq(type(rebuilt.historical), "table", "a reset history is never named by an old serial")
		helpers.assert_true(rebuilt.historical_serial ~= extended.historical_serial)
	end)

	helpers.it("names no serial in a payload saved to disk", function()
		-- The full projection becomes the next open's snapshot, read by another
		-- process whose serials restart at one.
		local projection, reader = fixture()
		local saved = range(projection, reader, "2026-10-20", false)
		helpers.assert_eq(type(saved.historical), "table")
		helpers.assert_nil(saved.historical_serial, "a persisted serial could name another process's history")
		local named = range(projection, reader, "2026-10-20", nil)
		helpers.assert_eq(type(named.historical_serial), "number", "the cached history is still named live")
	end)

	helpers.it("never names an incomplete history", function()
		local projection, reader, world = fixture()
		world.complete = false
		local partial = range(projection, reader, "2026-10-20", nil)
		helpers.assert_eq(type(partial.historical), "table")
		helpers.assert_nil(partial.historical_serial, "an uncached read cannot be reused")
		helpers.assert_eq(partial.incomplete, true)
	end)
end)
