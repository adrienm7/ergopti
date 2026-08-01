--- tests/unit/meta/test_corpus_keylogger_aggregation.lua

--- ==============================================================================
--- MODULE: Keylogger Aggregation Corpus Consumer (macOS)
--- DESCRIPTION:
--- Loads the cross-driver keylogger aggregation corpus from
--- _shared/tests/corpus/keylogger/aggregation_vectors.json and replays each
--- vector through the macOS aggregator (events.lua walk_typing etc.), then
--- asserts the resulting batch state matches the expected output.
---
--- This pins the macOS aggregation logic against the same golden vectors as
--- the AHK driver (KLW_WalkTypingEntry), so any divergence between the two
--- implementations is caught immediately.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===============================================
-- ===============================================
-- ======= 1/ Corpus Loading + Stub Setup ========
-- ===============================================
-- ===============================================

local corpus_path = helpers.shared("tests/corpus/keylogger/aggregation_vectors.json")

-- NOTE: no module-level stubs here — they would leak into other test files
-- (e.g. test_aggregator.lua). All stubs are set inside setup_and_replay()
-- so they only affect this file's vector execution

local function read_corpus()
	local fh = io.open(corpus_path, "r")
	if not fh then return nil, "cannot open corpus at " .. corpus_path end
	local raw = fh:read("*a")
	fh:close()
	local ok, result = pcall(require("hs").json.decode, raw)
	if not ok then return nil, "JSON parse error: " .. tostring(result) end
	return result, nil
end

local corpus_root, corpus_err = read_corpus()

--- Finds a corpus vector by its stable identifier instead of its array position.
--- The corpus deliberately grows as regressions are found; positional lookups
--- silently replay the wrong scenario after an insertion and can make a valid
--- cross-walker assertion fail against unrelated data.
--- @param id string
--- @return table|nil
local function vector_by_id(id)
	if not corpus_root or type(corpus_root.vectors) ~= "table" then return nil end
	for _, vector in ipairs(corpus_root.vectors) do
		if vector.id == id then return vector end
	end
	return nil
end





-- ===============================================
-- ===============================================
-- ======= 2/ Batch Reading Helpers ===============
-- ===============================================
-- ===============================================

--- Reads the live agg_batch via the shared state singleton.
--- @return table The current S.agg_batch (may be nil before first walk).
local function get_batch()
	local S = require("modules.keylogger.aggregator.state")
	return S.agg_batch
end

--- Reads a specific app_day row from the batch.
--- @param date string "YYYY-MM-DD".
--- @param app string Application name.
--- @return table|nil
local function read_app_day_row(date, app)
	local batch = get_batch()
	if not batch then return nil end
	return batch.app_day[date .. "\1" .. app]
end

--- Counts entries in a table (non-numeric keys).
--- @param tbl table|nil
--- @return integer
local function count_entries(tbl)
	if type(tbl) ~= "table" then return 0 end
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

--- Counts entries in a nested ngram sub-table.
--- @param batch table|nil
--- @param sub string Sub-table name within batch.ngram.
--- @return integer
local function count_ngram(batch, sub)
	if not batch or not batch.ngram or not batch.ngram[sub] then return 0 end
	return count_entries(batch.ngram[sub])
end

--- Reads the ngram context for an app.
--- @param app string Application name.
--- @return table|nil
local function read_ctx(app)
	local S = require("modules.keylogger.aggregator.state")
	if not S.ngram_ctx then return nil end
	return S.ngram_ctx[app]
end

--- Reads the ergo row for (date, app).
--- @param date string
--- @param app string
--- @return table|nil
local function read_ergo(date, app)
	local batch = get_batch()
	if not batch then return nil end
	return batch.ergo[date .. "\1" .. app]
end

--- Reads the kc_hold row for (date, app, keycode).
--- @param date string
--- @param app string
--- @param kc integer
--- @return table|nil
local function read_kc_hold(date, app, kc)
	local batch = get_batch()
	if not batch then return nil end
	return batch.kc_hold[date .. "\1" .. app .. "\1" .. tostring(kc)]
end

--- Reads the system_day row for a date.
--- @param date string
--- @return table|nil
local function read_system_day(date)
	local batch = get_batch()
	if not batch then return nil end
	return batch.system_day[date]
end

--- Reads the titles row for (date, app, title).
--- @param date string
--- @param app string
--- @param title string
--- @return table|nil
local function read_title(date, app, title)
	local batch = get_batch()
	if not batch then return nil end
	return batch.titles[date .. "\1" .. app .. "\1" .. title]
end

--- Reads the app_time row for (date, app).
--- @param date string
--- @param app string
--- @return table|nil
local function read_app_time(date, app)
	local batch = get_batch()
	if not batch then return nil end
	return batch.app_time[date .. "\1" .. app]
end

--- Sums all ms values across app_time entries for a given app.
--- @param app string
--- @return integer
local function sum_app_time_ms(app)
	local batch = get_batch()
	if not batch then return 0 end
	local total = 0
	for _, row in pairs(batch.app_time) do
		if row.app == app then
			total = total + (row.ms or 0)
		end
	end
	return total
end

--- Counts switches_to entries for a given prev_app.
--- @param app string
--- @return integer
local function count_switches_to(app)
	local batch = get_batch()
	if not batch then return 0 end
	local n = 0
	for _, row in pairs(batch.switches_to) do
		if row.app_from == app then n = n + 1 end
	end
	return n
end

--- Sums all ms values across titles entries.
--- @return integer
local function sum_titles_ms()
	local batch = get_batch()
	if not batch then return 0 end
	local total = 0
	for _, row in pairs(batch.titles) do
		total = total + (row.ms or 0)
	end
	return total
end

--- Reads the hourly row for (date, app, hour).
--- @param date string
--- @param app string
--- @param hour string
--- @return table|nil
local function read_hourly(date, app, hour)
	local batch = get_batch()
	if not batch then return nil end
	return batch.hourly[date .. "\1" .. app .. "\1" .. hour]
end

--- Reads the chars_class row for (date, app).
--- @param date string
--- @param app string
--- @return table|nil
local function read_chars_class(date, app)
	local batch = get_batch()
	if not batch then return nil end
	return batch.chars_class[date .. "\1" .. app]
end





-- ===============================================
-- ===============================================
-- ======= 3/ Vector Dispatcher ===================
-- ===============================================
-- ===============================================

--- Replays a single event entry through the correct walker.
--- @param agg table The aggregator module (freshly loaded + init'd).
--- @param entry table The corpus event entry.
local function replay_event(agg, entry)
	local etype = entry.type
	if etype == "typing" then
		-- Convert corpus format to the walker's expected shape
		local events = {}
		for _, ev in ipairs(entry.events) do
			events[#events + 1] = {
				ev.char,
				ev.delay,
				ev.meta or {},
			}
		end
		agg.walk_typing({
			app = entry.app,
			timestamp = entry.timestamp,
			events = events,
			layout = entry.layout,
			title = entry.title,
		})
	elseif etype == "app_switch" then
		agg.walk_app_switch({
			prev_app = entry.prev_app,
			next_app = entry.next_app,
			timestamp = entry.timestamp,
			duration_ms = entry.duration_ms,
		})
	elseif etype == "window_switch" then
		agg.walk_window_switch({
			app = entry.app,
			prev_title = entry.prev_title,
			timestamp = entry.timestamp,
			duration_ms = entry.duration_ms,
		})
	elseif etype == "system_event" then
		agg.walk_system_event(entry)
	end
end

--- Creates a fresh aggregator instance and replays all events in a vector.
--- @param vec table A corpus vector.
--- @return table The aggregator module after replay (for reading state).
local function setup_and_replay(vec)
	-- Reload the aggregator module fresh for each vector
	-- The implementation is split into core/events/state/sql modules. Clear each
	-- known member explicitly: mutating package.loaded during pairs() is not a
	-- portable invalidation strategy, and can leave an event walker capturing a
	-- previous Core/State singleton under a different discovery order in CI.
	package.loaded["modules.keylogger.aggregator"]       = nil
	package.loaded["modules.keylogger.aggregator.core"]  = nil
	package.loaded["modules.keylogger.aggregator.events"] = nil
	package.loaded["modules.keylogger.aggregator.sql"]   = nil
	package.loaded["modules.keylogger.aggregator.state"] = nil
	package.loaded["modules.keylogger.sqlite_writer"] = {
		get_db = function() return nil end,
		init   = function() end,
	}
	package.loaded["modules.keylogger.export"] = {
		get_native_app_category = function() return "Development" end,
		init = function() end,
	}
	package.loaded["infra.timings"] = {
		ms  = function(_section, key)
			if key == "think_pause_ms" then return 2000 end
			if key == "max_keystroke_delay_ms" then return 5000 end
			if key == "burst_gap_ms" then return 5000 end
			if key == "session_gap_ms" then return 300000 end
			if key == "auto_repeat_max_delay_ms" then return 50 end
			if key == "hold_threshold_ms" then return 200 end
			return 1000
		end,
		sec = function(_section, _key) return 1.0  end,
	}

	local agg = helpers.load_with_stubs("modules.keylogger.aggregator")

	-- Reset the shared state singleton — it persists across load_with_stubs
	-- reloads (only the top-level module is cleared, not its sub-modules),
	-- so a previous test's init() would leave S.initialized=true and leak
	local S = require("modules.keylogger.aggregator.state")
	S.initialized = false
	S.agg_batch   = nil
	S.ngram_ctx   = nil
	S.device_id   = nil

	agg.init({ device_id = "corpus-test-uuid" })

	for _, entry in ipairs(vec.events) do
		replay_event(agg, entry)
	end

	return agg
end





-- ===============================================
-- ===============================================
-- ======= 4/ Corpus Integrity ====================
-- ===============================================
-- ===============================================

helpers.describe("keylogger aggregation corpus — integrity", function()
	helpers.it("corpus file is readable and parseable", function()
		helpers.assert_true(corpus_root ~= nil,
			"corpus load error: " .. tostring(corpus_err))
		helpers.assert_true(type(corpus_root) == "table",
			"corpus root must be a table")
		helpers.assert_true(type(corpus_root.vectors) == "table",
			"corpus.vectors must be a table")
		helpers.assert_true(#corpus_root.vectors > 0,
			"corpus must have at least one vector")
	end)

	helpers.it("every vector has required fields: id, events, expected", function()
		if not corpus_root then return end
		for _, v in ipairs(corpus_root.vectors) do
			helpers.assert_true(type(v.id) == "string" and v.id ~= "",
				"vector missing id field")
			helpers.assert_true(type(v.events) == "table",
				"vector '" .. tostring(v.id) .. "' missing events array")
			helpers.assert_true(type(v.expected) == "table",
				"vector '" .. tostring(v.id) .. "' missing expected table")
		end
	end)
end)





-- ===============================================
-- ===============================================
-- ======= 5/ Vector Execution ====================
-- ===============================================
-- ===============================================

helpers.describe("keylogger aggregation corpus — vector replay", function()

	helpers.it("simple_typing_3_chars: 3 chars, n-grams, hourly, char class", function()
		if not corpus_root then return end
		local vec = vector_by_id("simple_typing_3_chars")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-06-01", "TestApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.chars, 3, "chars = 3")
		helpers.assert_eq(row.time_ms, 330, "time_ms = 100+120+110")
		helpers.assert_eq(row.pauses or 0, 0, "no think pauses")
		helpers.assert_eq(row.think_time_ms or 0, 0, "no think time")

		helpers.assert_eq(count_ngram(get_batch(), "ngram_chars"), 3, "3 char n-grams")
		helpers.assert_eq(count_ngram(get_batch(), "ngram_bigrams"), 2, "2 bigrams")
		helpers.assert_eq(count_ngram(get_batch(), "ngram_trigrams"), 1, "1 trigram")

		local hr = read_hourly("2024-06-01", "TestApp", "10")
		helpers.assert_true(hr ~= nil, "hourly row must exist")
		helpers.assert_eq(hr.c, 3, "hourly c = 3")

		local cc = read_chars_class("2024-06-01", "TestApp")
		helpers.assert_true(cc ~= nil, "chars_class row must exist")
		helpers.assert_eq(cc.letter, 3, "3 letters")

		local ctx = read_ctx("TestApp")
		helpers.assert_true(ctx ~= nil, "context for TestApp must exist")
		helpers.assert_eq(ctx.p1, "c", "last p1 = 'c'")
	end)

	helpers.it("typing_with_backspace: bs_total=1, cur_word='h'", function()
		if not corpus_root then return end
		local vec = vector_by_id("typing_with_backspace")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-06-01", "BSApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.chars, 3, "chars = 3 (h+e+bs — backspace counts as a char)")

		local er_row = get_batch() and get_batch().errors["2024-06-01\1BSApp"]
		helpers.assert_true(er_row ~= nil, "errors row must exist")
		helpers.assert_eq(er_row.bs_total, 1, "bs_total = 1")

		local ctx = read_ctx("BSApp")
		helpers.assert_true(ctx ~= nil, "context for BSApp must exist")
		helpers.assert_eq(ctx.cur_word, "h", "cur_word = 'h' after backspace")
		helpers.assert_eq(ctx.p1, "[BS]", "last p1 = '[BS]'")
	end)

	helpers.it("typing_with_word_boundary: cur_word='', prev_word='hi'", function()
		if not corpus_root then return end
		local vec = vector_by_id("typing_with_word_boundary")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local ctx = read_ctx("WordApp")
		helpers.assert_true(ctx ~= nil, "context for WordApp must exist")
		helpers.assert_eq(ctx.cur_word, "", "cur_word reset after space")
		helpers.assert_eq(ctx.prev_word, "hi", "prev_word = 'hi'")

		local cc = read_chars_class("2024-06-01", "WordApp")
		helpers.assert_true(cc ~= nil, "chars_class row must exist")
		helpers.assert_eq(cc.letter, 2, "2 letters")
		helpers.assert_eq(cc.space, 1, "1 space")
	end)

	helpers.it("synthetic_hotstring_trigger: hs_chars=2, hs_triggers=1", function()
		if not corpus_root then return end
		local vec = vector_by_id("synthetic_hotstring_trigger")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-06-01", "HsApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.chars, 1, "chars = 1 (only the real 'a')")
		helpers.assert_eq(row.hs_chars, 2, "hs_chars = 2 (synthetic x+y)")
		helpers.assert_eq(row.hs_triggers, 1, "hs_triggers = 1")
	end)

	helpers.it("synthetic_llm_trigger: llm_chars=2, llm_triggers=1", function()
		if not corpus_root then return end
		local vec = vector_by_id("synthetic_llm_trigger")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-06-01", "LlmApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.chars, 1, "chars = 1 (only the real 'a')")
		helpers.assert_eq(row.llm_chars, 2, "llm_chars = 2 (synthetic x+y)")
		helpers.assert_eq(row.llm_triggers, 1, "llm_triggers = 1")
	end)

	helpers.it("synthetic trigger deletes keep gross output so the UI subtracts input once", function()
		if not corpus_root then return end
		local vec = nil
		for _, candidate in ipairs(corpus_root.vectors) do
			if candidate.id == "synthetic_hotstring_backspace_keeps_gross_output" then
				vec = candidate
				break
			end
		end
		helpers.assert_true(vec ~= nil, "gross-output regression vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-06-01", "GrossHsApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.chars, 3, "manual trigger remains three real chars")
		helpers.assert_eq(row.hs_chars, 8, "hs_chars must be gross generated output")
		helpers.assert_eq(row.hs_input_chars, 3, "deleted trigger is recorded separately")
		helpers.assert_eq(row.hs_chars - row.hs_input_chars, 5,
			"source-filtered UI must see the five-character net gain exactly once")
	end)

	helpers.it("typing_with_think_pause: pauses=1, think_time_ms=3000", function()
		if not corpus_root then return end
		local vec = vector_by_id("typing_with_think_pause")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-06-01", "PauseApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.chars, 3, "chars = 3")
		helpers.assert_eq(row.pauses, 1, "1 think pause (delay > think_pause_ms)")
		helpers.assert_eq(row.think_time_ms, 3000, "think_time = 3000")
		helpers.assert_eq(row.time_ms, 200, "time_ms = 100+100 (the 5000 goes to think_time)")

		local ctx = read_ctx("PauseApp")
		helpers.assert_true(ctx ~= nil)
		helpers.assert_eq(ctx.p1, "c", "last p1 = 'c'")
		helpers.assert_eq(ctx.cur_word, "abc", "cur_word = 'abc' (no separator to flush)")
	end)

	helpers.it("app_switch_accumulates_duration: app_time=8000, switches_to=2", function()
		if not corpus_root then return end
		local vec = vector_by_id("app_switch_accumulates_duration")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		helpers.assert_eq(count_entries(get_batch() and get_batch().app_time), 1, "1 app_time entry")
		helpers.assert_eq(sum_app_time_ms("AppA"), 8000, "app_time total = 5000+3000")
		helpers.assert_eq(count_switches_to("AppA"), 2, "2 switches_to entries")
	end)

	helpers.it("window_switch_credits_title_ms: titles_ms=12000", function()
		if not corpus_root then return end
		local vec = vector_by_id("window_switch_credits_title_ms")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		helpers.assert_eq(count_entries(get_batch() and get_batch().titles), 1, "1 title entry")
		helpers.assert_eq(sum_titles_ms(), 12000, "titles ms total = 12000")
	end)

	helpers.it("system_event_wifi_change: wifi_changes=2", function()
		if not corpus_root then return end
		local vec = vector_by_id("system_event_wifi_change")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local sday = read_system_day("2024-06-01")
		helpers.assert_true(sday ~= nil, "system_day row must exist")
		helpers.assert_eq(sday.wifi_changes, 2, "wifi_changes = 2")
	end)

	helpers.it("system_event_modifier_hold: kc_hold count=2, sum=500, max=300", function()
		if not corpus_root then return end
		local vec = vector_by_id("system_event_modifier_hold")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local r = read_kc_hold("2024-06-01", "TestApp", 56)
		helpers.assert_true(r ~= nil, "kc_hold row must exist")
		helpers.assert_eq(r.count, 2, "count = 2")
		helpers.assert_eq(r.sum_ms, 500, "sum_ms = 300+200")
		helpers.assert_eq(r.max_ms, 300, "max_ms = 300")
	end)

	helpers.it("system_event_manifest_increment_hs: hs_suggested=2", function()
		if not corpus_root then return end
		local vec = vector_by_id("system_event_manifest_increment_hs")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-06-01", "TestApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.hs_suggested, 2, "hs_suggested = 2")
	end)

	helpers.it("mixed_batch_typing_and_system: chars=1, ergo focus_sum=300", function()
		if not corpus_root then return end
		local vec = vector_by_id("mixed_batch_typing_and_system")
		helpers.assert_true(vec ~= nil, "vector missing")
		setup_and_replay(vec)

		local row = read_app_day_row("2024-07-02", "MixedApp")
		helpers.assert_true(row ~= nil, "app_day row must exist")
		helpers.assert_eq(row.chars, 1, "chars = 1")

		local eg = read_ergo("2024-07-02", "MixedApp")
		helpers.assert_true(eg ~= nil, "ergo row must exist")
		helpers.assert_eq(eg.focus_to_first_key_sum_ms, 300, "focus sum = 300")
		helpers.assert_eq(eg.focus_to_first_key_count, 1, "focus count = 1")
	end)
end)




-- ===============================================
-- ===============================================
-- ======= 6/ Cleanup ============================
-- ===============================================
-- ===============================================

helpers.describe("keylogger aggregation corpus — cleanup", function()
	helpers.it("resets aggregator state singleton to prevent leak into other tests", function()
		local S = require("modules.keylogger.aggregator.state")
		S.initialized = false
		S.agg_batch   = nil
		S.ngram_ctx   = nil
		S.device_id   = nil
	end)
end)
