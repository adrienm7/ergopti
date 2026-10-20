--- tests/support/keylogger/ledger_native_process.lua

--- ==============================================================================
--- MODULE: Ledger Native IO Subprocess
--- DESCRIPTION:
--- Actual Lua stdio and the canonical append/atomic publishers, with SQLite
--- requests served by the suite's existing owned Python SQLite bridge. Native
--- metadata/lock ports remain portable controls, not a Cocoa qualification.
--- ==============================================================================

return function()
	local root, temporary = assert(arg[3]), assert(arg[2])
	local driver = root .. "/static/ergopti_plus/macos"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
		.. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
		.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
	local json = require("json")
	local helpers = require("tests.helpers")
	local function request(message)
		message.kind = "request"
		assert(io.stdout:write(json.encode(message) .. "\n")); assert(io.stdout:flush())
		local response = assert(json.decode_lossless(assert(io.stdin:read("*l"))))
		assert(response.ok, response.error); return response.value
	end
	local function open(path)
		local identity = request({ op = "open", path = path })
		local db = {}
		function db:exec(sql) return request({ op = "exec", connection = identity, sql = sql }) end
		function db:nrows(sql)
			local rows = request({ op = "rows", connection = identity, sql = sql })
			for _, row in ipairs(rows) do for key, value in pairs(row) do if json.is_null(value) then row[key] = nil end end end
			local index = 0
			return function() index = index + 1; return rows[index] end
		end
		function db:close() return request({ op = "close", connection = identity }) end
		return db
	end
	local fixture = require("tests.support.file_system_transaction_fixture")
	fixture.with_fixture(function(native)
		package.loaded["adapters.file_system"] = native.make_adapter()
		local errors, logger = {}, helpers.make_logger_stub()
		logger.error = function(_, message, ...) errors[#errors + 1] = string.format(message, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.timings"] = { sec = function() return 5 end, ms = function() return 5000 end }
		package.loaded["keylogger.metrics"] = {}
		local aggregator = { get_ngram_ctx = function() return {} end }
		for _, key in ipairs({ "init", "flush", "reset_batch", "reset_ngram_ctx", "set_device_id", "set_ngram_ctx",
			"walk_typing", "walk_app_switch", "walk_window_switch", "walk_system_event" }) do
			aggregator[key] = function() return true end
		end
		package.loaded["modules.keylogger.aggregator"] = aggregator
		local export = helpers.load_with_stubs("modules.keylogger.export")
		package.loaded["modules.keylogger.export"] = { init = function() end,
			sync_foreign_data_sql = function() return {} end, _last_complete_batch_offset = export._last_complete_batch_offset }
		local db, opened, timers, offset = nil, false, {}, nil
		local path = temporary .. "/metrics/by_device/device/data.sql"
		local db_path = temporary .. "/ergopti_metrics/device/db.sqlite"
		local writer = { init = function() end }
		function writer.open_db()
			local missing = not require("lfs").attributes(db_path)
			db = open(db_path); opened = true
			if missing then
				for _, name in ipairs({ "schema.sql", "media_schema.sql" }) do
					local file = assert(io.open(root .. "/static/ergopti_plus/_shared/data/db/" .. name, "rb"))
					local schema = assert(file:read("*a")); assert(file:close()); assert(db:exec(schema) == 0)
				end
				for key, value in pairs({ local_data_sql_outbox = "", today_log_offset = "0",
					today_log_date = "", ngram_ctx_json = "{}", next_event_id = "1" }) do
					assert(db:exec("INSERT OR IGNORE INTO meta VALUES('" .. key .. "','" .. value .. "');") == 0)
				end
			end
			return true
		end
		function writer.get_db() return db end
		function writer.close_db() if db then assert(db:close() == 0); db = nil end; return true end
		writer.get_next_event_id = function() return 101 end
		writer.set_next_event_id = function() end
		writer.persist_next_event_id = function() return true end
		package.loaded["modules.keylogger.sqlite_writer"] = writer
		local rotation = { init = function(options) offset = options.today_log_offset end,
			is_initialized = function() return true end, read_new_entries = function() return {}, 0, "eof" end }
		package.loaded["modules.keylogger.rotation"] = rotation
		local phase = assert(os.getenv("ERGOPTI_LEDGER_IO_PHASE"))
		local original_open = io.open
		local lfs = require("lfs")
		local manager = helpers.load_with_stubs("modules.keylogger.log_manager", {
			fs = { attributes = lfs.attributes, dir = lfs.dir, mkdir = lfs.mkdir, symlinkAttributes = lfs.symlinkattributes },
			execute = function() return "fixture-host-identity" end,
			timer = { absoluteTime = function() return 1000000000 end, secondsSinceEpoch = function() return 1 end,
				new = function()
				local timer = { active = false }
				function timer:start() self.active = true; return self end
				function timer:stop() self.active = false; return self end
				function timer:running() return self.active end
				timers[#timers + 1] = timer; return timer
			end },
		})
		local function upvalue(fn, wanted)
			for index = 1, math.huge do
				local name, value = debug.getupvalue(fn, index)
				assert(name, "missing actual manager ownership: " .. wanted)
				if name == wanted then return value end
			end
		end
		if phase == "cache_loss" then
			assert(manager.init({ LOG_DIR = temporary .. "/metrics" }), "actual fresh-cache manager init must succeed: " .. table.concat(errors, " | "))
			assert(offset == 123, "actual startup must replay the repaired batch before restoring its cursor: " .. tostring(offset) .. " | " .. table.concat(errors, " | "))
		else
			assert(writer.open_db())
			upvalue(upvalue(manager.ingest_once, "_flush_local_data_sql_outbox"), "_paths").data_sql_path = path
			if phase == "prepare" then
				-- Publish intent normally, then refuse before acquiring an append stream.
				io.open = function(file_path, mode)
					if file_path == path and (mode == "a" or mode == "ab") then return nil, "prepare append admission refused" end
					return original_open(file_path, mode)
				end
			end
			manager.ingest_once()
		end
		local remaining, events = nil, nil
		for row in db:nrows("SELECT value FROM meta WHERE key='local_data_sql_outbox'") do remaining = #row.value end
		for row in db:nrows("SELECT COUNT(*) AS n FROM events_system") do events = row.n end
		assert(manager.stop({ process_exit = true }), "actual manager shutdown must retire its native owners")
		io.open = original_open
		assert(writer.get_db() == nil, "shutdown retained a SQLite connection")
		for _, timer in ipairs(timers) do assert(timer:running() == false) end
		print(json.encode({ kind = "done", phase = phase, remaining = remaining, events = events,
			opened = opened, cursor = offset or 0, timers = #timers, timers_retired = true }))
	end)
end
