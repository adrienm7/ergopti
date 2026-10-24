--- tests/meta/corpus/test_corpus_keystats_aggregation.lua

--- ==============================================================================
--- MODULE: Keystats Aggregation Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays the typing streams of _shared/tests/corpus/keystats/
--- aggregation_vectors.json through the Linux aggregate walker, the same file
--- macOS (events.lua) and Windows (KLW_WalkTypingEntry) replay. The Linux walker
--- owns the n-gram, character class, correction, hourly, burst, session and
--- context outcomes; every other expected key names the Linux module that owns
--- it instead, so a key the corpus gains can never pass unasserted.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Walker = helpers.load_module("modules.keystats.aggregate_walker")

local SEPARATOR = "\1"

-- Expected keys the Linux walker does not own, with the module that does. The
-- live per-application counters are kept by keystats.lua and the system facts
-- by system_metrics.lua, so the walker never sees them.
local KEYSTATS = "modules/keystats/keystats.lua live application counters"
local OWNED_ELSEWHERE = {
	app_day = KEYSTATS,
	app_day_chars = KEYSTATS,
	app_day_hs_suggested = KEYSTATS,
	app_time_count = KEYSTATS .. " (focus time)",
	app_time_ms_total = KEYSTATS .. " (focus time)",
	switches_to_count = KEYSTATS .. " written by sqlite_writer.lua",
	titles_count = KEYSTATS .. " written by sqlite_writer.lua",
	titles_ms_total = KEYSTATS .. " written by sqlite_writer.lua",
	system_day_wifi_changes = "modules/keystats/system_metrics.lua",
	kc_hold_count = KEYSTATS .. " fed by adapters/keyboard_hook.lua",
	kc_hold_sum_ms = KEYSTATS .. " fed by adapters/keyboard_hook.lua",
	kc_hold_max_ms = KEYSTATS .. " fed by adapters/keyboard_hook.lua",
	-- Known gap: the walker seeds these fields at zero and no Linux producer
	-- measures focus-to-first-key latency yet.
	ergo_focus_sum_ms = "no Linux producer yet (the walker seeds it at zero)",
	ergo_focus_count = "no Linux producer yet (the walker seeds it at zero)",
}

-- Expected keys the walker answers; read() maps each to its batch or context field.
local REPLAYED = {
	ngram_chars_count = true, ngram_bigrams_count = true, ngram_trigrams_count = true,
	ngram_chars_total_delay_ms = true, ngram_chars_delay_count = true, ngram_zero_delay_tokens = true,
	hourly_c = true, chars_class_letter = true, chars_class_space = true, errors_bs_total = true,
	last_p1 = true, last_cur_word = true, last_prev_word = true,
	burst_count_total = true, burst_open_chars = true, session_count_total = true, session_open_chars = true,
}

local function read_corpus()
	local path = assert(require("infra.paths").shared("tests/corpus/keystats/aggregation_vectors.json"))
	local handle = assert(io.open(path, "rb"))
	local data = assert(Json.decode(assert(handle:read("*a"))))
	assert(handle:close())
	return data
end

--- Converts the corpus wall-clock stamp into local epoch milliseconds.
--- @param stamp string "YYYY-MM-DD HH:MM:SS.mmm".
--- @return number milliseconds
local function epoch_ms(stamp)
	local y, mo, d, h, mi, s = stamp:match("^(%d+)-(%d+)-(%d+) (%d+):(%d+):(%d+)")
	return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
		hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }) * 1000
end

--- Walks every typing entry of a vector with a carried context and real stamps.
--- @param vector table Corpus vector.
--- @return table batch, table ctx, string date, string app
local function replay(vector)
	local batch, ctx, date, app = nil, {}, nil, nil
	for _, entry in ipairs(vector.events) do
		if entry.type == "typing" then
			date, app = entry.timestamp:sub(1, 10), entry.app
			local events, times, at = {}, {}, epoch_ms(entry.timestamp)
			for index, ev in ipairs(entry.events) do
				if index > 1 then at = at + ev.delay end
				events[#events + 1] = { ev.char, ev.delay, ev.meta or {} }
				times[#times + 1] = at
			end
			batch = Walker.walk(events, date, app, batch, { times = times, wall_offset_ms = 0 }, ctx)
		end
	end
	return batch, ctx, date, app
end

--- Reads one walker-owned outcome by its corpus key.
--- @return any value
local function read(key, batch, ctx, date, app)
	local prefix = date .. SEPARATOR .. app
	local function rows(family)
		local count, delay, samples = 0, 0, 0
		for row_key, row in pairs(batch.ngram[family]) do
			if row_key:sub(1, #prefix + 1) == prefix .. SEPARATOR and row.c > 0 then
				count, delay, samples = count + 1, delay + row.td, samples + row.cd
			end
		end
		return count, delay, samples
	end
	local family = key:match("^(ngram_[a-z]+)_count$")
	if family then return (rows(family)) end
	if key == "ngram_chars_total_delay_ms" then return (select(2, rows("ngram_chars"))) end
	if key == "ngram_chars_delay_count" then return (select(3, rows("ngram_chars"))) end
	if key == "hourly_c" then
		local total = 0
		for _, row in pairs(batch.hourly) do if row.app == app and row.date == date then total = total + row.c end end
		return total
	end
	local class = key:match("^chars_class_(%a+)$")
	if class then return batch.chars_class[prefix][class] end
	if key == "errors_bs_total" then return batch.errors[prefix].bs_total end
	if key == "last_p1" then return ctx.run[#ctx.run] end
	if key == "last_cur_word" then return ctx.word end
	if key == "last_prev_word" then return ctx.previous_word end
	if key == "burst_count_total" then return batch.bursts[prefix].count_total end
	if key == "session_count_total" then return batch.sessions[prefix].count_total end
	if key == "burst_open_chars" then return ctx.burst.char_count end
	if key == "session_open_chars" then return ctx.session.char_count end
	error("no walker field for corpus key " .. key)
end

local corpus = read_corpus()

helpers.describe("keystats aggregation corpus through the Linux walker (corpus-keystats-aggregation)", function()
	helpers.it("every expected key is replayed or names its Linux owner", function()
		for _, vector in ipairs(corpus.vectors) do
			for key in pairs(vector.expected) do
				helpers.assert_true(REPLAYED[key] or OWNED_ELSEWHERE[key] ~= nil,
					vector.id .. ": key " .. key .. " is neither replayed nor owned elsewhere")
			end
		end
	end)

	for _, vector in ipairs(corpus.vectors) do
		local fixed, typed = vector, false
		for _, entry in ipairs(vector.events) do typed = typed or entry.type == "typing" end
		if typed then
			helpers.it(fixed.id, function()
				local batch, ctx, date, app = replay(fixed)
				local asserted = 0
				for key, expected in pairs(fixed.expected) do
					if key == "ngram_zero_delay_tokens" then
						for _, token in ipairs(expected) do
							local item = batch.ngram.ngram_chars[date .. SEPARATOR .. app .. SEPARATOR .. token]
							helpers.assert_true(item ~= nil, fixed.id .. ": unigram " .. token)
							helpers.assert_eq({ item.td, item.cd }, { 0, 0 }, fixed.id .. ": long-gap unigram " .. token)
						end
						asserted = asserted + 1
					elseif OWNED_ELSEWHERE[key] == nil then
						local actual = read(key, batch, ctx, date, app)
						helpers.assert_eq(actual, expected, fixed.id .. ": " .. key)
						asserted = asserted + 1
					end
				end
				-- A typing vector whose every key lives elsewhere still proves the walk ran.
				helpers.assert_true(asserted > 0 or next(batch.ngram.ngram_chars) ~= nil, fixed.id .. " asserted nothing")
			end)
		end
	end
end)
