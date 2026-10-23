--- tests/unit/ui/metrics/test_metrics_typing_projection_publication.lua

--- ==============================================================================
--- MODULE: Typing projection cache publication regression tests
--- DESCRIPTION:
--- The typing dashboard caches n-gram history per range and extends it by the
--- days added since its watermark. Two partial side effects survived a failure:
--- 1. The extension merged the new days INTO the cached dict, then encoded it
---    through pausable work before moving the watermark. A job abandoned at
---    one of those pauses left the merged counts under the old watermark, so
---    the next job merged the same days again and doubled them
---    (typing-range-abandon-2026-10-21).
--- 2. read_ngrams reported no completeness, so a history read whose queries
---    failed was cached and certified by the fingerprint until the past data
---    changed (typing-range-incomplete-2026-10-21).
--- ==============================================================================

local helpers = require("tests.helpers")

local ABANDONED = setmetatable({}, { __tostring = function() return "job abandoned at a pause" end })
local TOKENS = 600

--- Fake reader over a per-day count of TOKENS tokens; day "D" holds `per_day[D]`.
--- @param per_day table date -> count per token
--- @param failing table|nil set of dates whose read is incomplete
--- @return table reader, table pacer
local function fake_reader(per_day, failing)
	local Real = helpers.load_with_stubs("modules.keylogger.sqlite_reader")
	local pacer = { armed = false }
	function pacer.pause()
		if pacer.armed then
			pacer.armed = false
			error(ABANDONED)
		end
	end
	local reader = { next_day = Real.next_day }
	function reader.split_bounds(_start, _end, today)
		local y, m, d = today:match("^(%d+)%-(%d+)%-(%d+)$")
		local yesterday = os.date("%Y-%m-%d", os.time({ year = y, month = m, day = d - 1, hour = 12 }))
		return { historical_end = yesterday, includes_today = true }
	end
	function reader.fingerprint() return "unchanged" end
	function reader.read_today_split() return {} end
	function reader.read_ngrams(_path, start_date, end_date)
		local out = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {}, sc = {}, sc_bg = {}, w_bg = {}, kc = {} }
		local complete = true
		for date, count in pairs(per_day) do
			if (not start_date or date >= start_date) and date <= end_date then
				if failing and failing[date] then
					complete = false
				else
					for index = 1, TOKENS do
						local token = "t" .. index
						local item = out.c[token] or { c = 0, t = 0, e = 0, hs = 0, llm = 0, o = 0 }
						item.c = item.c + count
						out.c[token] = item
					end
				end
			end
		end
		return out, complete
	end
	function reader.merge_ngrams(into, from)
		local merged = Real.merge_ngrams(into, from)
		pacer.armed = pacer.arm_after_merge == true
		return merged
	end
	return reader, pacer
end

local function load_projection()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local projection = helpers.load_with_stubs("ui.metrics_typing.projection")
	projection.reset()
	return projection
end

local function count_of(json, token)
	return tonumber(json:match('"' .. token .. '":{[^}]-"c":(%d+)'))
end


helpers.describe("typing projection publishes only complete, settled history", function()
	helpers.it("does not double-count days merged by an abandoned job (typing-range-abandon-2026-10-21)", function()
		local projection = load_projection()
		local per_day = { ["2026-10-18"] = 1, ["2026-10-19"] = 1, ["2026-10-20"] = 1 }
		local reader, pacer = fake_reader(per_day)

		-- Day one: history through 2026-10-19 is projected and cached.
		projection.session(reader, "/db.sqlite", "2026-10-20", pacer).range("2026-10-18", nil, nil)
		-- Day two: the extension by 2026-10-20 is abandoned during its encode.
		pacer.arm_after_merge = true
		local abandoned = pcall(function()
			projection.session(reader, "/db.sqlite", "2026-10-21", pacer).range("2026-10-18", nil, nil)
		end)
		helpers.assert_eq(abandoned, false, "the fixture must abandon the extension")
		pacer.arm_after_merge = false
		-- The next job on day two must count each of the three days once.
		local json = projection.session(reader, "/db.sqlite", "2026-10-21", pacer).range("2026-10-18", nil, nil)
		helpers.assert_eq(count_of(json, "t1"), 3, "2026-10-20 must not be merged twice")
	end)

	helpers.it("does not cache an incomplete history read (typing-range-incomplete-2026-10-21)", function()
		local projection = load_projection()
		local per_day = { ["2026-10-18"] = 1, ["2026-10-19"] = 1 }
		local failing = { ["2026-10-19"] = true }
		local reader, pacer = fake_reader(per_day, failing)
		local first = projection.session(reader, "/db.sqlite", "2026-10-20", pacer).range("2026-10-18", nil, nil)
		helpers.assert_eq(count_of(first, "t1"), 1, "the incomplete read still shows what it could read")
		failing["2026-10-19"] = nil
		local second = projection.session(reader, "/db.sqlite", "2026-10-20", pacer).range("2026-10-18", nil, nil)
		helpers.assert_eq(count_of(second, "t1"), 2, "a recovered source must be read again, not served from cache")
	end)
end)
