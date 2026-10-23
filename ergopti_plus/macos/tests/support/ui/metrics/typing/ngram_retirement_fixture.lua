--- tests/support/ui/metrics/typing/ngram_retirement_fixture.lua

--- ==============================================================================
--- MODULE: Typing History Retirement Fixture
--- DESCRIPTION:
--- Exercises public dashboard cancellation around real paced history encodes.
--- Native ports are deterministic; the reader, projection and job remain real.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local FakeSqlite = require("tests.support.fake_ngram_sqlite")
local with_delivery = require("tests.support.typing_delivery_fixture")
local M = {}

M.PAST, M.NEXT, M.TODAY = "2026-10-18", "2026-10-19", "2026-10-20"

--- Observes an owned closure without replacing its behavior.
--- @param fn function Closure.
--- @param wanted string Upvalue name.
--- @return any value
local function upvalue(fn, wanted)
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == wanted then return value end
	end
	error("Required observation upvalue absent: " .. wanted)
end

--- Counts one historical token.
--- @param data table N-gram dict.
--- @param token string Token.
--- @return number count
function M.count(data, token)
	return data.c[token] and data.c[token].c or 0
end

--- Runs a real UI lifecycle with exact module and native-state restoration.
--- @param callback function Receives scenario controls after healthy bootstrap.
function M.run(callback)
	local original_date = os.date
	local ok, detail = xpcall(function()
		helpers.with_fresh_modules({ "hs.sqlite3" }, function()
			with_delivery(function(dashboard, context, timers, errors, _, evaluations)
				local state = { dashboard = dashboard, errors = errors, day = M.NEXT,
					now_ns = 0, merges = 0, histories = {}, cut = false }
				os.date = function(format, timestamp)
					if format == "%Y-%m-%d" and timestamp == nil then return state.day end
					return original_date(format, timestamp)
				end
				local tables = {
					ngram_chars = {}, ngram_bigrams = {}, ngram_trigrams = {}, ngram_quadgrams = {},
					ngram_pentagrams = {}, ngram_hexagrams = {}, ngram_heptagrams = {},
					ngram_words = {}, ngram_word_bigrams = {}, ngram_shortcuts = {},
					ngram_shortcut_bigrams = {}, ngram_keycodes = {},
					agg_app_day = {
						{ date = M.PAST, app = "Editor", chars = 107 },
						{ date = M.NEXT, app = "Editor", chars = 11 },
					},
				}
				local function add(date, token, value)
					local row = { date = date, app = "Editor", token = token, c = value,
						td = value * 100, e = 0, esrc_json = "{}" }
					tables.ngram_chars[#tables.ngram_chars + 1] = row
					return row
				end
				add(M.PAST, "a", 7)
				state.extension_row = add(M.NEXT, "b", 11)
				for index = 1, 100 do add(M.PAST, "padding-" .. index, 1) end
				function state.pad_today()
					for index = 1, 100 do add(M.TODAY, "today-padding-" .. index, 1) end
				end
				local sqlite = FakeSqlite.new(tables)
				local original_open = sqlite.open
				function sqlite.open(...)
					local db = original_open(...)
					local original_rows = db.nrows
					function db:nrows(sql)
						local source = sql:match("FROM ([%w_]+)")
						local bounds = sql:find("SELECT (SELECT MIN(date)", 1, true) ~= nil
						local fingerprint = sql:find("COUNT(*) AS n", 1, true) ~= nil
						local lo = sql:match("date >= '([%d%-]+)'")
						if state.sql_refusal and source == "ngram_chars" and not bounds
							and not fingerprint and lo == M.NEXT then
							error("controlled SQLITE_BUSY historical row refusal")
						end
						if source == "agg_app_day" and not bounds and not fingerprint then
							local hi = sql:match("date <= '([%d%-]+)'")
							local selected = {}
							for _, row in ipairs(tables.agg_app_day) do
								if (not lo or row.date >= lo) and (not hi or row.date <= hi) then
									selected[#selected + 1] = row
								end
							end
							local index = 0
							return function() index = index + 1; return selected[index] end
						end
						return original_rows(self, sql)
					end
					return db
				end
				package.loaded["hs.sqlite3"] = sqlite
				package.loaded["hs.json"].encode = Json.encode
				package.loaded["hs.json"].decode = Json.decode
				local old_attributes = package.loaded["hs.fs"].attributes
				package.loaded["hs.fs"].attributes = function(path, ...)
					if path == "/fixture/db.sqlite" then return { mode = "file" } end
					return old_attributes(path, ...)
				end
				package.loaded["modules.keylogger.log_manager"].get_sqlite_path = function()
					return "/fixture/db.sqlite"
				end
				package.loaded["modules.keylogger.sqlite_reader"] = nil
				local reader = require("modules.keylogger.sqlite_reader")
				local projection = require("ui.metrics_typing.projection")
				local encoder = require("infra.paced_json").encode
				state.reader, state.projection = reader, projection
				dashboard._app_icon_cache.Editor = false
				local original_read, original_merge = reader.read_ngrams, reader.merge_ngrams
				reader.read_ngrams = function(...)
					local result = table.pack(original_read(...))
					state.history_data = result[1]
					state.histories[#state.histories + 1] = { complete = result[2] }
					return table.unpack(result, 1, result.n)
				end
				reader.merge_ngrams = function(into, from)
					local result = table.pack(original_merge(into, from))
					state.merges, state.history_data = state.merges + 1, into
					return table.unpack(result, 1, result.n)
				end
				local original_today = reader.read_today_split
				reader.read_today_split = function(...)
					local result = table.pack(original_today(...))
					state.today_data = result[1]
					return table.unpack(result, 1, result.n)
				end
				local native_hs = assert(_G.hs)
				native_hs.timer.absoluteTime = function()
					local boundary = false
					if state.armed and not state.cut then
						for depth = 2, 48 do
							local info = debug.getinfo(depth, "fS")
							if not info then break end
							if state.armed == "before-merge" and state.merges == 0
								and info.source:gsub("\\", "/"):sub(-#"modules/keylogger/sqlite_reader.lua")
									== "modules/keylogger/sqlite_reader.lua" then boundary = true end
							if info.func == encoder then
								local name, value = debug.getlocal(depth, 1)
								assert(name == "value", "The real encoder value parameter must be observable")
								boundary = state.armed == "history-json" and rawequal(value, state.history_data)
									or state.armed == "today-json" and rawequal(value, state.today_data)
							end
							if boundary then break end
						end
					end
					if boundary then
						state.now_ns, state.cut = state.now_ns + 20000000, true
					end
					return state.now_ns
				end
				local pending_query, next_timer = nil, 1
				local function flush_callbacks()
					local index = 1
					while index <= #evaluations do
						local call = evaluations[index]
						if not call.received then
							call.received = true
							local full = call.code:match("^window%.publishTypingMetricsData%((.*)%)%;$")
							local range = call.code:match("^window%.receive_range_data%((.*)%)$")
							if full then
								state.last_delivery = Json.decode("[" .. full .. "]")[1].initial_data
							elseif range then
								state.last_delivery = Json.decode("[" .. range .. "]")[1]
							end
							if call.code == "window._lua_request" then
								local query = pending_query
								pending_query = nil
								call.done(query and Json.encode(query) or nil, nil)
							else
								call.done(call.code:sub(1, 7) == "typeof " and "function" or true, nil)
							end
						end
						index = index + 1
					end
				end
				local function pump_one()
					flush_callbacks()
					while next_timer <= #timers do
						local callback = timers[next_timer]
						next_timer = next_timer + 1
						if upvalue(callback, "handle").timer ~= nil then
							callback()
							flush_callbacks()
							return true
						end
					end
					return false
				end
				function state.drain()
					local turns = 0
					while pump_one() do
						turns = turns + 1
						assert(turns < 10000, "Bounded timer census exceeded")
					end
					assert(dashboard._job == nil, "A completed publication must retire its paced job")
				end
				function state.ranges() return upvalue(projection.reset, "_ranges") end
				function state.entry()
					for _, entry in ipairs(state.ranges()) do
						if entry.key == state.key then return entry end
					end
				end
				function state.arm(boundary) state.armed, state.cut = boundary, false end
				function state.suspend()
					local turns = 0
					while not state.cut and pump_one() do
						turns = turns + 1
						assert(turns < 10000, "Target boundary was not reached")
					end
					assert(state.cut and dashboard._job and dashboard._job.state == "running",
						"A suspended real paced job is required")
				end
				function state.request(id)
					pending_query = { start_date = M.PAST, end_date = M.TODAY,
						apps = { "Editor" }, request_id = id or 71 }
					context.poll()
					flush_callbacks()
				end
				function state.close()
					local job = dashboard._job
					assert(dashboard.close() == true)
					if job then assert(job.state == "cancelled" and job.timer == nil) end
					return job
				end
				local builder = package.loaded["ui.ui_builder"]
				local original_show = builder.show_webview
				builder.show_webview = function(options)
					local prototype = original_show(options)
					local fresh = setmetatable({}, { __index = prototype })
					context.webview = fresh
					return fresh
				end
				function state.reopen() assert(dashboard.show() == true) end
				function state.advance() state.day = M.TODAY end
				function state.assert_complete()
					local entry = assert(state.entry(), "A successful retry must admit its history")
					assert(entry.through == M.NEXT)
					assert(M.count(entry.data, "a") == 7 and M.count(entry.data, "b") == 11)
					local encoded = Json.decode(entry.json)
					assert(M.count(encoded, "a") == 7 and M.count(encoded, "b") == 11)
				end
				function state.assert_published()
					local delivered = assert(state.last_delivery, "A real WebView publication is required")
					assert(M.count(delivered.historical, "a") == 7)
					assert(M.count(delivered.historical, "b") == 11)
				end
				local scenario_ok, scenario_error = xpcall(function()
					state.drain()
					local ranges = state.ranges()
					assert(#ranges == 1, "Healthy bootstrap must admit one open-ended history")
					state.baseline, state.key = ranges[1], ranges[1].key
					assert(state.baseline.through == M.PAST and M.count(state.baseline.data, "b") == 0)
					callback(state)
				end, debug.traceback)
				local cleanup_ok, cleanup_error = pcall(state.close)
				if not scenario_ok then error(scenario_error, 0) end
				if not cleanup_ok then error(cleanup_error, 0) end
			end)
		end)
	end, debug.traceback)
	os.date = original_date
	if not ok then error(detail, 0) end
end

return M
