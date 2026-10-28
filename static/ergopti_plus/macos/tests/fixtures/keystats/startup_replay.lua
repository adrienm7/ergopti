--- tests/fixtures/keystats/startup_replay.lua

--- ==============================================================================
--- MODULE: Cold Ledger Replay with Real SQLite
--- DESCRIPTION:
--- Drives public manager initialization through physical ledger files and the
--- existing SQLite bridge. Only native metadata/process ports are controlled;
--- no main-thread responsiveness result is claimed for a physical Mac.
--- ==============================================================================

local root, temporary = assert(arg[3]), assert(arg[2])
assert(os.getenv("HOME") == temporary and os.getenv("TMPDIR") == temporary, "owned runtime directories required")
local driver = root .. "/static/ergopti_plus/macos"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua"
package.cpath = ""
local Json, Helpers = require("json"), require("tests.helpers")

local function rpc(message)
	message.kind = "request"
	assert(io.stdout:write(Json.encode(message) .. "\n")); assert(io.stdout:flush())
	return assert(Json.decode_lossless(assert(io.stdin:read("*l"))))
end
local function request(message)
	local response = rpc(message)
	assert(response.ok, response.error)
	return response.value
end
local function metadata(path, follow)
	local response = rpc({ op = follow and "stat_identity" or "lstat_identity", path = path })
	if response.ok ~= true then return nil, response.error end
	if response.value == false then return nil, "No such file or directory" end
	local value = response.value
	value.mode, value.type = value.type, nil
	return value
end
local function sqlite_open(path)
	local identity = request({ op = "open", path = path })
	local db = { last_error = "", opened = true }
	function db:exec(sql)
		local response = rpc({ op = "exec", connection = identity, sql = sql })
		self.last_error = response.error or ""
		return response.ok and response.value or 1
	end
	function db:nrows(sql)
		local rows = request({ op = "rows", connection = identity, sql = sql })
		for _, row in ipairs(rows) do
			for key, value in pairs(row) do if Json.is_null(value) then row[key] = nil end end
		end
		local index = 0
		return function() index = index + 1; return rows[index] end
	end
	function db:prepare(sql)
		local statement = {}
		function statement:bind_values(...) self.values = { ... }; return 0 end
		function statement:step()
			local response = rpc({ op = "bound", connection = identity, sql = sql, values = self.values })
			db.last_error = response.error or ""
			return response.ok and 101 or 1
		end
		function statement:finalize() return 0 end
		return statement
	end
	function db:errmsg() return self.last_error end
	function db:isopen() return self.opened end
	function db:close()
		local closed = request({ op = "close", connection = identity })
		self.opened = false
		return closed
	end
	return db
end

_G.hs = require("tests.stubs.hs")
local loop = require("tests.support.runloop_timers").create()
hs.fs.attributes = function(path) return metadata(path, true) end
hs.fs.symlinkAttributes = function(path) return metadata(path, false) end
hs.fs.mkdir = function(path)
	local response = rpc({ op = "mkdir", path = path })
	return response.ok and true or nil, response.error
end
hs.fs.rmdir = os.remove
local physical_fs = hs.fs
local sqlite_port, json_port = hs.sqlite3, hs.json
sqlite_port.open = sqlite_open
for _, name in ipairs({ "fs", "json", "sqlite3" }) do package.loaded["hs." .. name] = hs[name] end
package.loaded["hs.timer"] = loop.api
hs.timer = loop.api
local errors, logger = {}, Helpers.make_logger_stub()
logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
package.loaded["infra.logger"] = logger
local Export = require("modules.keystats.export")
package.loaded["modules.keystats.export"] = {
	init = function() return true end, cleanup = function() return true end,
	sync_foreign_data_sql = function() return {} end, get_native_app_category = function() return nil end,
	_last_complete_batch_offset = Export._last_complete_batch_offset,
	_typing_rollover_boundaries = Export._typing_rollover_boundaries,
}

require("tests.support.file_system_transaction_fixture").with_fixture(function(native)
	local function link(source, destination, symbolic)
		assert(symbolic == false, "initial ledger must use an exclusive hard link")
		local response = rpc({ op = "link", source = source, destination = destination })
		return response.ok and true or nil, response.error
	end
	package.loaded["adapters.file_system"] = native.make_adapter(nil, nil, nil, link)
	hs.timer = loop.api
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.ledger_append"] = nil
	package.loaded["infra.logger"] = logger
	package.loaded["hs.sqlite3"], package.loaded["hs.json"], package.loaded["hs.timer"] = sqlite_port, json_port, loop.api
	local Writer = require("modules.keystats.sqlite_writer")
	local Manager = require("modules.keystats.log_manager")
	local paths = { sqlite_path = temporary .. "/cache.sqlite", today_log_path = temporary .. "/today.log",
		data_sql_path = temporary .. "/data.sql", metrics_dir = temporary .. "/", by_device_dir = temporary .. "/",
		tmpdir_dir = temporary .. "/", device_json_path = temporary .. "/device.json" }
	local function upvalue(fn, wanted, replacement)
		for index = 1, math.huge do
			local name, value = debug.getupvalue(fn, index)
			assert(name, "missing fixture ownership boundary " .. wanted)
			if name == wanted then
				if replacement ~= nil then debug.setupvalue(fn, index, replacement) end
				return value
			end
		end
	end
	local init = upvalue(Manager.init, "_init")
	upvalue(init, "_resolve_device", function()
		return { device_id = "bootstrap-proof", name = "Proof", os = "darwin", host_signature = "proof",
			created_at = "2026-10-26 00:00:00.000" }, false
	end)
	upvalue(init, "_resolve_paths", function() return paths end)
	-- Every selected directory is the already-owned temporary root. Directory
	-- policy and native device discovery are independent from header publication.
	upvalue(init, "_mkdir_p", function() return true end)

	local sentinel, initialized = false, false
	local mode = assert(os.getenv("ERGOPTI_STARTUP_REPLAY_MODE"))
	local fault = mode:match("^fault_(.+)$")
	local close_admitted = true
	local last_synchronous = nil
	local original_open, source_reads, live_streams = io.open, 0, {}
	io.open = function(path, access)
		local handle, detail, code = original_open(path, access)
		if not handle or path ~= paths.data_sql_path or access ~= "rb" then return handle, detail, code end
		local stream = { native = handle }
		live_streams[#live_streams + 1] = stream
		function stream:seek(...) return self.native:seek(...) end
		function stream:read(count)
			source_reads = source_reads + 1
			if fault == "read" and source_reads == 3 then return nil, "controlled replay read refusal" end
			return self.native:read(count)
		end
		function stream:close()
			if not close_admitted then return nil, "controlled replay close refusal" end
			return self.native:close()
		end
		return stream
	end
	local Scheduler = require("adapters.timer_scheduler")
	local original_after, original_cancel = Scheduler.after, Scheduler.cancel
	if fault == "schedule" then Scheduler.after = function() return nil, false end end
	local cancelled_once = false
	if fault == "cancel" then
		Scheduler.cancel = function(handle)
			if not cancelled_once then cancelled_once = true; return false end
			return original_cancel(handle)
		end
	end
	local original_sqlite_open = sqlite_port.open
	sqlite_port.open = function(path)
		local db = original_sqlite_open(path)
		local execute = db.exec
		local off_seen = false
		function db:exec(sql)
			if sql == "PRAGMA synchronous = OFF;" then off_seen = true end
			if fault == "durability" and off_seen and sql == "PRAGMA synchronous = FULL;" then
				self.last_error = "controlled durable-mode restoration refusal"; return 1
			end
			local metadata_keys = { date_publication = "today_log_date", context_publication = "ngram_ctx_json" }
			local refused_key = metadata_keys[fault]
			if refused_key and sql:find("WHERE key='" .. refused_key .. "'", 1, true)
				and sql:find("UPDATE meta", 1, true) then
				self.last_error = "controlled replay metadata publication refusal"; return 1
			end
			if fault == "pending_delete" and sql:find("DELETE FROM meta WHERE key='local_ledger_replay'", 1, true) then
				self.last_error = "controlled replay completion refusal"; return 1
			end
			if fault == "id_publication" and sql:find("WHERE key='next_event_id'", 1, true)
				and sql:find("UPDATE meta", 1, true) then
				self.last_error = "controlled event-id publication refusal"; return 1
			end
			if (fault == "sql" and sql:find("INSERT OR IGNORE INTO events_system", 1, true))
				or (fault == "publication" and sql:find("WHERE key='today_log_offset'", 1, true)
					and sql:find("UPDATE meta", 1, true)) then
				self.last_error = "controlled replay SQL refusal"
				return 1
			end
			local result = execute(self, sql)
			if result == 0 and sql == "PRAGMA synchronous = OFF;" then last_synchronous = 0 end
			if result == 0 and sql == "PRAGMA synchronous = FULL;" then last_synchronous = 2 end
			return result
		end
		return db
	end
	local first_timer
	first_timer = loop.api.new(0, function() sentinel = true; first_timer:stop() end)
	first_timer:start()
	initialized = Manager.init({ LOG_DIR = temporary })
	assert(initialized, table.concat(errors, " | "))
	local db = assert(Writer.get_db())
	local rows_after_return = 0
	for row in db:nrows("SELECT COUNT(*) AS n FROM events_system") do rows_after_return = row.n end
	local first_turn = loop.step()
	local responsive = sentinel and (rows_after_return < 3200 or mode == "warm")
	local turns = 0
	if mode ~= "cancel" and fault ~= "cancel" then
		while Manager.is_recovering() and (not fault or #errors == 0) do
			assert(loop.step(), "recovery lost its next timer")
			turns = turns + 1
			assert(turns < 10000, "recovery failed to settle: " .. table.concat(errors, " | "))
		end
	end
	local raw_rows, cursor, revision, next_id
	for row in db:nrows("SELECT COUNT(*) AS n FROM events_system") do raw_rows = row.n end
	for row in db:nrows("SELECT value FROM meta WHERE key='today_log_offset'") do cursor = tonumber(row.value) end
	for row in db:nrows("SELECT value FROM meta WHERE key='aggregate_cache_revision'") do revision = row.value end
	for row in db:nrows("SELECT value FROM meta WHERE key='next_event_id'") do next_id = tonumber(row.value) end
	local pending_rows, synchronous = 0, nil
	for row in db:nrows("SELECT COUNT(*) AS n FROM meta WHERE key='local_ledger_replay'") do pending_rows = row.n end
	for row in db:nrows("PRAGMA synchronous") do synchronous = row.synchronous end
	local Rotation = require("modules.keystats.rotation")
	local read_entries, rotation_reads = Rotation.read_new_entries, 0
	Rotation.read_new_entries = function(...) rotation_reads = rotation_reads + 1; return read_entries(...) end
	local blocked = fault and Manager.ingest_once() == false or nil
	local first_stop, live_after_refusal, stale_callback_blocked
	if fault == "close" or fault == "cancel" then
		first_stop = Manager.stop({ process_exit = true })
		live_after_refusal = Writer.get_db() ~= nil and Writer.get_db():isopen()
		local calls_before = source_reads
		for _, candidate in ipairs(loop.queue) do candidate.callback() end
		stale_callback_blocked = source_reads == calls_before
		close_admitted = true
	end
	fault = nil
	local reads_before_stop = rotation_reads
	local recovering_before_stop = Manager.is_recovering()
	local stopped = Manager.stop({ process_exit = false })
	local stop_read_delta = rotation_reads - reads_before_stop
	io.open = original_open
	Scheduler.after, Scheduler.cancel = original_after, original_cancel
	for _, stream in ipairs(live_streams) do assert(io.type(stream.native) == "closed file", "owned replay reader leaked") end

	assert(io.stdout:write(Json.encode({ kind = "done", initialized = initialized,
		rows_after_init = rows_after_return, sentinel_before_complete = responsive,
		raw_rows = raw_rows, cursor = cursor, revision = revision, next_id = next_id,
		first_turn = first_turn, turns = turns, stopped = stopped, errors = errors,
		blocked = blocked, first_stop = first_stop, live_after_refusal = live_after_refusal,
		rotation_reads_after_failure = reads_before_stop, stop_read_delta = stop_read_delta,
		recovering_before_stop = recovering_before_stop, replay_pending_rows = pending_rows, synchronous = synchronous, durability_restored = last_synchronous == 2,
		stale_callback_blocked = stale_callback_blocked }) .. "\n"))
	assert(io.stdout:flush())
end, { fs = physical_fs })
