--- _shared/tests/corpus/logger/parity_replay.lua

--- ==============================================================================
--- MODULE: Logger Parity Corpus Replay (Lua)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/logger/parity_vectors.json for the macOS and
--- Linux suites. Each suite passes the entry points of its own driver, so the
--- cases run against the code that driver ships; the Windows suite replays the
--- same file in tests/meta/corpus/test_corpus_logger_parity.ahk.
--- ==============================================================================

--- Converts "YYYY-MM-DD HH:MM:SS" to local epoch seconds.
--- @param text string
--- @return number
local function epoch(text)
	local year, month, day, hour, min, sec = text:match("^(%d+)%-(%d+)%-(%d+) (%d+):(%d+):(%d+)$")
	assert(year, "parity corpus: malformed instant " .. tostring(text))
	return os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day),
		hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec) })
end

--- Runs every case of the sections that name `ctx.driver`.
--- @param ctx table { helpers, corpus, driver, core_path,
---   resolve_level = fn(stored, absent) -> level, threshold, refused,
---   detailed_log = fn(stored, absent) -> ticked, level a click stores,
---   default_level = string, emit_body = fn(template, argument) -> body,
---   dated_expired = fn(date, now, days) -> boolean }
return function(ctx)
	local helpers, corpus = ctx.helpers, ctx.corpus
	local describe, it = helpers.describe, helpers.it
	local assert_eq, assert_true = helpers.assert_eq, helpers.assert_true

	local function replayed(name)
		local section = corpus[name]
		assert(type(section) == "table" and type(section.cases) == "table" and #section.cases > 0,
			"parity corpus: the " .. name .. " section is empty")
		for _, driver in ipairs(section.drivers) do
			if driver == ctx.driver then return section end
		end
		error("parity corpus: the " .. name .. " section does not name the " .. ctx.driver .. " driver", 2)
	end

	describe("logger parity level_setting (" .. ctx.driver .. ")", function()
		local section = replayed("level_setting")
		it("the declared default is the corpus default", function()
			assert_eq(ctx.default_level, section.default)
		end)
		for _, case in ipairs(section.cases) do
			it("logger parity level_setting: " .. case.id, function()
				local level, threshold, refused = ctx.resolve_level(case.stored, case.stored_absent == true)
				assert_eq(level, case.level, case.id .. ": level")
				assert_eq(threshold, case.threshold, case.id .. ": threshold")
				assert_eq(refused, case.refused, case.id .. ": refused")
			end)
		end
	end)

	describe("logger parity detailed_log (" .. ctx.driver .. ")", function()
		local section = replayed("detailed_log")
		for _, case in ipairs(section.cases) do
			it("logger parity detailed_log: " .. case.id, function()
				local ticked, target = ctx.detailed_log(case.stored, case.stored_absent == true)
				assert_eq(ticked, case.ticked, case.id .. ": ticked")
				assert_eq(target, case.click_stores, case.id .. ": the level a click stores")
			end)
		end
	end)

	describe("logger parity format_failure (" .. ctx.driver .. ")", function()
		local section = replayed("format_failure")
		for _, case in ipairs(section.cases) do
			it("logger parity format_failure: " .. case.id, function()
				local argument = case.argument == "object" and {} or case.argument
				local body = ctx.emit_body(case.lua_template, argument)
				if case.failed then
					local head = case.lua_template .. section.marker
					assert_eq(body:sub(1, #head), head, case.id .. ": the template, then the marker: " .. body)
					assert_eq(body:sub(-#case.expect_suffix), case.expect_suffix, case.id .. ": the lost-argument count")
				else
					assert_eq(body, case.expect_body, case.id .. ": the substituted body")
				end
			end)
		end
	end)

	describe("logger parity retention (" .. ctx.driver .. ")", function()
		for _, case in ipairs(replayed("dated_retention").cases) do
			it("logger parity dated_retention: " .. case.id, function()
				assert_eq(ctx.dated_expired(case.file_date, epoch(case.now), case.retention_days) == true,
					case.purged, case.id)
			end)
		end
	end)

	describe("logger parity sink_failure (" .. ctx.driver .. ")", function()
		local section = replayed("sink_failure")
		for _, case in ipairs(section.cases) do
			it("logger parity sink_failure: " .. case.id, function()
				-- A fresh core: the driver's singleton holds the driver's own sink
				local core = dofile(ctx.core_path)
				core.timestamp_fn = function() return "2026-11-20 10:00:00:000" end
				local accepted, calls = {}, 0
				core.set_sink(function(line)
					calls = calls + 1
					if calls <= case.refuse_first then error(case.error, 0) end
					accepted[#accepted + 1] = line:match("^%S+ %S+ %[[A-Z]+%] %[[^%]]+%] (.*)$")
				end)
				for _, body in ipairs(case.emit) do core.info("parity", body) end
				assert_eq(#accepted, #case.expect, case.id .. ": accepted line count")
				for index, want in ipairs(case.expect) do
					if want.body then
						assert_eq(accepted[index], want.body, case.id .. ": line " .. index)
					else
						local expected = string.format(section.report_template, want.report_count,
							want.report_count == 1 and "line was" or "lines were", case.error)
						assert_eq(accepted[index], expected, case.id .. ": report " .. index)
					end
				end
				local pending = core.sink_refusals()
				assert_true(pending == 0, case.id .. ": every refusal must have been reported")
			end)
		end
	end)
end
