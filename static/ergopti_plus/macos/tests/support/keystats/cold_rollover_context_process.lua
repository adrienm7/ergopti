--- tests/support/keystats/cold_rollover_context_process.lua

--- ==============================================================================
--- MODULE: Cold Rollover Context Native Process
--- DESCRIPTION:
--- Actual storage modules and private native streams with the existing Python
--- SQLite bridge. Metadata/lock ports remain portable controls, not Cocoa proof.
--- ==============================================================================

local function main()
	local root, temporary = assert(arg[3]), assert(arg[2])
	local driver = root .. "/static/ergopti_plus/macos"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
		.. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
		.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
	local Json = require("json")
	local Helpers = require("tests.helpers")
	local Lfs = require("lfs")
	local phase = assert(os.getenv("ERGOPTI_COLD_NGRAM_PHASE"))
	assert(phase == "seed" or phase == "warm" or phase == "cold")
	local OLD, NEW = "2026-10-20", "2026-10-21"
	local active_day = phase == "seed" and OLD or NEW
	local real_date, real_open = os.date, io.open
	local ledger = temporary .. "/metrics/by_device/device/data.sql"
	local journal = temporary .. "/metrics/by_device/device/today.log"
	local cache = temporary .. "/ergopti_metrics/device/db.sqlite"
	local timers, native_streams = {}, {}
	local errors, warnings, sqlite_live = {}, {}, false
	local result, manager, writer, rotation, scheduler = nil, nil, nil, nil, nil

	local function read_file(path)
		local stream = assert(real_open(path, "rb"))
		local bytes = assert(stream:read("*a"))
		assert(stream:close())
		return bytes
	end

	local function rpc(message)
		message.kind = "request"
		assert(io.stdout:write(Json.encode(message) .. "\n"))
		assert(io.stdout:flush())
		return assert(Json.decode_lossless(assert(io.stdin:read("*l"))))
	end

	local function request(message)
		local response = rpc(message)
		assert(response.ok, response.error)
		return response.value
	end

	local function open_database(path)
		assert(path == cache, "SQLite escaped the owned disposable cache")
		local identity = request({ op = "open", path = path })
		sqlite_live = true
		local database = { last_error = "" }
		function database:exec(sql)
			local response = rpc({ op = "exec", connection = identity, sql = sql })
			self.last_error = response.error or ""
			return response.ok and response.value or 1
		end
		function database:nrows(sql)
			local rows = request({ op = "rows", connection = identity, sql = sql })
			for _, row in ipairs(rows) do
				for key, value in pairs(row) do if Json.is_null(value) then row[key] = nil end end
			end
			local index = 0
			return function() index = index + 1; return rows[index] end
		end
		function database:prepare(sql)
			local statement = { values = nil, finalized = false }
			function statement:bind_values(...)
				assert(not self.finalized)
				self.values = { ... }
				return 0
			end
			function statement:step()
				assert(not self.finalized and self.values)
				local response = rpc({ op = "bound", connection = identity, sql = sql, values = self.values })
				database.last_error = response.error or ""
				return response.ok and 101 or 1
			end
			function statement:finalize()
				assert(not self.finalized); self.finalized = true
				return 0
			end
			return statement
		end
		function database:errmsg() return self.last_error end
		function database:isopen() return sqlite_live end
		function database:close()
			local status = request({ op = "close", connection = identity })
			sqlite_live = false
			return status
		end
		return database
	end

	local function new_timer(seconds, callback)
		local timer = { active = false, seconds = seconds, callback = callback, starts = 0, stops = 0 }
		function timer:start() self.active = true; self.starts = self.starts + 1; return self end
		function timer:stop() self.active = false; self.stops = self.stops + 1; return self end
		function timer:running() return self.active end
		timers[#timers + 1] = timer
		return timer
	end

	local function retire()
		local outcomes = {}
		if manager then
			local ok, stopped = pcall(manager.stop, { process_exit = true })
			outcomes.manager_stop_call_ok, outcomes.manager_stop = ok, stopped == true
		end
		if scheduler then
			local ok, stopped = pcall(scheduler.cancelAll)
			outcomes.scheduler_cancel_call_ok, outcomes.scheduler_cancel = ok, stopped ~= false
		end
		outcomes.streams_closed = 0
		-- Rotation currently exposes no public close method. These are the exact
		-- native append capabilities this private fixture acquired, never a path
		-- reopened for cleanup. The process exit remains a separate waited boundary.
		for _, observed in ipairs(native_streams) do
			local stream = observed.handle
			if io.type(stream) == "file" then
				local ok, closed = pcall(stream.close, stream)
				assert(ok and closed == true, "owned rotation stream cleanup refused")
				outcomes.streams_closed = outcomes.streams_closed + 1
			end
		end
		outcomes.all_streams_closed = true
		for _, observed in ipairs(native_streams) do
			if io.type(observed.handle) ~= "closed file" then outcomes.all_streams_closed = false end
		end
		assert(outcomes.all_streams_closed, "an owned native stream remains open")
		outcomes.stream_inventory = #native_streams
		outcomes.timers_retired = true
		for _, timer in ipairs(timers) do
			if timer:running() then outcomes.timers_retired = false end
		end
		outcomes.sqlite_retired = not sqlite_live
		assert(outcomes.manager_stop_call_ok and outcomes.manager_stop)
		assert(outcomes.scheduler_cancel_call_ok and outcomes.scheduler_cancel)
		assert(outcomes.timers_retired and outcomes.sqlite_retired)
		return outcomes
	end

	local function rows(sql)
		local result = {}
		for row in assert(writer.get_db()):nrows(sql) do result[#result + 1] = row end
		return result
	end
	local function observations()
		local raw = rows("SELECT id,ts,date,app,text,events_json FROM events_typing ORDER BY id")
		local data = {raw = raw, words = {}, bigrams = {}, trigrams = {}, chars = {},
			meta = rows("SELECT key,value FROM meta WHERE key IN ('today_log_offset','today_log_date',"
				.. "'ngram_ctx_json','local_data_sql_outbox','aggregate_cache_revision','next_event_id') ORDER BY key")}
		for _, item in ipairs({{"words", "ngram_words"}, {"bigrams", "ngram_bigrams"},
			{"trigrams", "ngram_trigrams"}, {"chars", "ngram_chars"}}) do
			data[item[1]] = rows("SELECT date,app,token,c FROM " .. item[2]
				.. " WHERE device_id='device' ORDER BY date,app,token")
		end
		data.offset, data.date = rotation.get_offset(), rotation.get_date()
		return data
	end

	local Fixture = require("tests.support.file_system_transaction_fixture")
	Fixture.with_fixture(function(native)
		local outcome = table.pack(xpcall(function()
			local adapter = native.make_adapter()
			Helpers.load_with_stubs("hs", {
				fs = {attributes = Lfs.attributes, dir = Lfs.dir, mkdir = Lfs.mkdir,
					rmdir = Lfs.rmdir, symlinkAttributes = Lfs.symlinkattributes},
				json = {encode = Json.encode, decode = Json.decode_lossless},
				sqlite3 = {OK = 0, ERROR = 1, DONE = 101, ROW = 100, open = open_database},
				execute = function(command)
					assert(command:find("IOPlatformUUID", 1, true), "unexpected shell command")
					return "fixture-host-identity", true, "exit", 0
				end,
				timer = {new = new_timer, absoluteTime = function() return 1000000000 end,
					secondsSinceEpoch = function() return 1792497600 end},
			})
			package.loaded["adapters.file_system"] = adapter
			local logger = Helpers.make_logger_stub()
			logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
			logger.warn = function(_, message, ...) warnings[#warnings + 1] = string.format(message, ...) end
			package.loaded["infra.logger"] = logger
			os.date = function(format, epoch)
				if format == "%Y-%m-%d" and epoch == nil then return active_day end
				return real_date(format, epoch)
			end
			io.open = function(path, mode)
				local handle, detail, code = real_open(path, mode)
				if handle then native_streams[#native_streams + 1] = {handle = handle, path = path, mode = mode} end
				return handle, detail, code
			end
			local payload_path = assert(os.getenv("ERGOPTI_COLD_NGRAM_PAYLOAD"))
			local payload = assert(Json.decode_lossless(read_file(payload_path)))
			manager = require("modules.keystats.log_manager")
			writer = require("modules.keystats.sqlite_writer")
			rotation = require("modules.keystats.rotation")
			scheduler = require("adapters.timer_scheduler")
			assert(require("modules.keystats.text_cipher").is_enabled() == false,
				"regression requires native default unencrypted typing rows")
			local before_ingest
			if phase ~= "seed" then
				local ordinary_ingest = manager.ingest_once
				manager.ingest_once = function(...)
					if not before_ingest then
						before_ingest = observations()
						before_ingest.live_context = Json.decode_lossless(Json.encode(
							require("modules.keystats.aggregator").get_ngram_ctx()))
					end
					return ordinary_ingest(...)
				end
			end
			assert(manager.init({LOG_DIR = temporary .. "/metrics"}), table.concat(errors, " | "))
			assert(writer.get_db() ~= nil, "actual SQLite handle was not admitted")
			if phase == "seed" then
				assert(manager.append_log(payload.old))
				manager.ingest_once()
				local old = observations()
				assert(#old.raw == 1 and old.raw[1].text == "x", "seed old typing did not persist")
				active_day = NEW
				assert(manager.day_rollover() == true, "healthy public rollover must acknowledge success")
				local reset = observations()
				local values = {}; for _, row in ipairs(reset.meta) do values[row.key] = row.value end
				assert(reset.offset == 0 and reset.date == NEW and values.today_log_offset == "0"
					and values.today_log_date == NEW, "healthy rollover cursor reset did not commit")
				local context = assert(Json.decode_lossless(values.ngram_ctx_json))
				assert(type(context) == "table" and next(context) == nil,
					"healthy rollover did not commit the documented empty context")
				local live = require("modules.keystats.aggregator").get_ngram_ctx()
				assert(type(live) == "table" and next(live) == nil, "healthy live context was not reset")
				assert(manager.append_log(payload.new))
				-- Public process_exit stop below drains FIFO without ingesting it.
				result = {kind = "done", phase = phase, old = old, reset = reset,
					pre_stop = observations(), new_queued = true}
			else
				local first = observations()
				manager.ingest_once()
				local second = observations()
				result = {kind = "done", phase = phase, before_ingest = before_ingest, first = first, second = second}
			end
		end, debug.traceback))
		os.date = real_date
		local cleanup_ok, cleanup = pcall(retire)
		io.open = real_open
		if not outcome[1] then error(outcome[2], 0) end
		assert(cleanup_ok, cleanup)
		result.cleanup, result.errors, result.warnings = cleanup, Json.array(errors), Json.array(warnings)
		assert(io.stdout:write(Json.encode(result) .. "\n")); assert(io.stdout:flush())
	end)
end

main()

