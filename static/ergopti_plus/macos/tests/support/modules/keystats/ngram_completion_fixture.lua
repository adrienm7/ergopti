--- tests/support/modules/keystats/ngram_completion_fixture.lua

--- ==============================================================================
--- MODULE: N-gram Read Completion Fixture
--- DESCRIPTION:
--- Compose the real reader and history projection around native query refusals.
--- ==============================================================================

local helpers = require("tests.helpers")
local FakeSqlite = require("tests.support.fake_ngram_sqlite")
local M = {}

M.PAST, M.NEXT, M.TODAY = "2026-10-18", "2026-10-19", "2026-10-20"
M.FAMILIES = {
	{ code = "c", table = "ngram_chars" },
	{ code = "bg", table = "ngram_bigrams" },
	{ code = "tg", table = "ngram_trigrams" },
	{ code = "qg", table = "ngram_quadgrams" },
	{ code = "pg", table = "ngram_pentagrams" },
	{ code = "hx", table = "ngram_hexagrams" },
	{ code = "hp", table = "ngram_heptagrams" },
	{ code = "w", table = "ngram_words" },
	{ code = "w_bg", table = "ngram_word_bigrams" },
	{ code = "sc", table = "ngram_shortcuts" },
	{ code = "sc_bg", table = "ngram_shortcut_bigrams" },
	{ code = "kc", table = "ngram_keycodes" },
}

local OWNERS = {
	"modules.keystats.sqlite_reader", "ui.metrics_typing.projection", "infra.paced_json",
	"infra.logger", "hs.sqlite3", "hs.json", "json",
}

--- Returns an iterator over the original row identities.
--- @param rows table Source rows.
--- @return function iterator
local function iterator(rows)
	local index = 0
	return function() index = index + 1; return rows[index] end
end

--- Creates native-port query controls without replacing any reader result.
--- @param options table|nil Empty-source and failure controls.
--- @return table state SQLite module and mutable refusal state.
function M.new(options)
	options = options or {}
	local state = { failure = options.failure, target = options.target or "ngram_chars",
		opens = 0, closes = 0, errors = {}, warnings = {}, reads = {}, histories = {}, pauses = 0 }
	local dates = { M.PAST, M.NEXT }
	if options.today then dates[#dates + 1] = M.TODAY end
	local tables = { agg_app_day = {} }
	for _, family in ipairs(M.FAMILIES) do
		local rows = {}
		tables[family.table] = rows
		if not options.empty then
			for day_index, date in ipairs(dates) do
				for slot = 1, 2 do
					rows[#rows + 1] = { date = date, app = "Editor",
						token = slot == 1 and (day_index == 1 and "a" or "b") or (day_index == 1 and "x" or "y"),
						keycode = 10 + day_index * 2 + slot - 1,
						c = slot == 1 and (day_index == 1 and 7 or 11) or (day_index == 1 and 2 or 4),
						td = 700, e = 0, esrc_json = "{}" }
				end
			end
		end
	end
	if not options.empty then
		tables.agg_app_day = {}
		for index, date in ipairs(dates) do
			tables.agg_app_day[#tables.agg_app_day + 1] = { date = date, app = "Editor", chars = index == 1 and 7 or 11 }
		end
	end
	local native = FakeSqlite.new(tables)
	local sqlite = { OK = native.OK }
	function sqlite.open()
		state.opens = state.opens + 1
		if state.refuse_open_at == state.opens then return nil, "controlled database open refusal" end
		local db = native.open()
		local original_rows, original_close = db.nrows, db.close
		function db:close()
			state.closes = state.closes + 1
			return original_close(self)
		end
		function db:nrows(sql)
			local source = sql:match("FROM ([%w_]+)")
			local fingerprint = sql:find("COUNT(*) AS n", 1, true) ~= nil
			local bounds = sql:find("SELECT (SELECT MIN(date)", 1, true) ~= nil
			state.reads[#state.reads + 1] = { source = source, fingerprint = fingerprint,
				bounds = bounds, day = sql:match("date = '([%d%-]+)'"), first = sql:match("date >= '([%d%-]+)'"), last = sql:match("date <= '([%d%-]+)'") }
			local today_query = sql:match("date = '([%d%-]+)'") == M.TODAY
			local refused = source == state.target and not fingerprint and state.failure ~= nil
				and (not options.today_only or today_query)
				and (not options.history_only or not today_query)
			if refused and state.failure == "bounds" and bounds then error("controlled SQLITE_BUSY bounds refusal") end
			if refused and not bounds and state.failure == "rows" then error("controlled SQLITE_BUSY row refusal") end
			local rows
			if source == "agg_app_day" and not fingerprint and not bounds then
				local lo, hi = sql:match("date >= '([%d%-]+)'"), sql:match("date <= '([%d%-]+)'")
				local selected = {}
				for _, row in ipairs(tables.agg_app_day) do
					if (not lo or row.date >= lo) and (not hi or row.date <= hi) then selected[#selected + 1] = row end
				end
				rows = iterator(selected)
			else
				rows = original_rows(self, sql)
			end
			if refused and not bounds and state.failure == "after-row" then
				local delivered = 0
				return function()
					if delivered == 1 then error("controlled SQLITE_BUSY after accepted row") end
					local row = rows()
					if row then delivered = delivered + 1 end
					return row
				end
			end
			return rows
		end
		return db
	end
	state.sqlite = sqlite
	state.pacer = { pause = function() state.pauses = state.pauses + 1 end }
	return state
end

--- Runs an isolated composition with exact package and native-state restoration.
--- @param options table|nil Native-port controls.
--- @param callback function Receives state, real reader and real projection.
--- @return ... Callback results.
function M.run(options, callback)
	return helpers.with_stub_scope(OWNERS, function()
		local state = M.new(options)
		local logger = helpers.make_logger_stub()
		logger.error = function(_, template, ...) state.errors[#state.errors + 1] = string.format(template, ...) end
		logger.warn = function(_, template, ...) state.warnings[#state.warnings + 1] = string.format(template, ...) end
		package.loaded["infra.logger"] = logger
		local reader = helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = state.sqlite })
		local original_read = reader.read_ngrams
		reader.read_ngrams = function(path, first, last, apps, pacer)
			local data, complete = original_read(path, first, last, apps, pacer)
			state.histories[#state.histories + 1] = { first = first, last = last, complete = complete }
			return data, complete
		end
		return callback(state, reader, require("ui.metrics_typing.projection"))
	end)
end

return M
