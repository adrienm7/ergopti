--- tests/fixtures/keystats/ledger_bootstrap.lua

--- ==============================================================================
--- MODULE: Physical Initial Ledger Publication Fixture
--- DESCRIPTION:
--- Public initialization must publish a complete create-only SQL header before
--- admitting the journal or SQLite. Python supplies actual filesystem identity
--- and SQLite; portable modes model documented FILE refusal boundaries, while
--- the explicitly selected Linux case induces native buffered fclose EFBIG.
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
local errors, logger = {}, Helpers.make_logger_stub()
logger.error = function(_, format, ...) errors[#errors + 1] = string.format(format, ...) end
package.loaded["infra.logger"] = logger
local Export = require("modules.keystats.export")
package.loaded["modules.keystats.export"] = {
	init = function() return true end, cleanup = function() return true end,
	sync_foreign_data_sql = function() return {} end, get_native_app_category = function() return nil end,
	_last_complete_batch_offset = Export._last_complete_batch_offset,
}

require("tests.support.file_system_transaction_fixture").with_fixture(function(native)
	local function link(source, destination, symbolic)
		assert(symbolic == false, "initial ledger must use an exclusive hard link")
		local response = rpc({ op = "link", source = source, destination = destination })
		return response.ok and true or nil, response.error
	end
	package.loaded["adapters.file_system"] = native.make_adapter(nil, nil, nil, link)
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
	local mode = assert(os.getenv("ERGOPTI_LEDGER_BOOTSTRAP_MODE"))
	assert(mode == "native" or mode == "portable_close" or mode == "portable_write")
	local original_open, streams, refused = io.open, {}, false
	local failed_write, failed_close, header_bytes
	io.open = function(path, access)
		local stream, detail, code = original_open(path, access)
		if not stream then return stream, detail, code end
		streams[#streams + 1] = stream
		if access ~= "w" then return stream, detail, code end
		local fault, buffered
		local proxy = {}
		function proxy:write(bytes)
			if not refused and bytes:find("^%-%- ergopti metrics") then
				refused, fault, header_bytes = true, true, bytes
				if mode == "portable_close" then
					-- Model stdio accepting the full row into its userspace buffer.
					buffered = bytes
					failed_write = { accepted = true }
					return self
				elseif mode == "portable_write" then
					assert(stream:setvbuf("no")); assert(stream:write(bytes:sub(1, #bytes - 6)))
					failed_write = { accepted = false, code = 28 }
					return nil, "injected native-style write refusal", 28
				end
				request({ op = "stat", path = paths.data_sql_path, native_write_limit = #bytes - 6 })
				local result, reason, number = stream:write(bytes)
				failed_write = { accepted = result == stream, error = reason, code = number }
				return result, reason, number
			end
			return stream:write(bytes)
		end
		function proxy:close()
			if fault and mode == "portable_close" then
				assert(stream:setvbuf("no")); assert(stream:write(buffered:sub(1, #buffered - 6)))
				assert(stream:close())
				failed_close = { accepted = false, code = 28, native_closed = io.type(stream) == "closed file" }
				return nil, "injected native-style buffered close refusal", 28
			end
			local result, reason, number = stream:close()
			if fault then
				failed_close = { accepted = result == true, error = reason, code = number,
					native_closed = io.type(stream) == "closed file" }
				if mode == "native" then request({ op = "stat", path = paths.data_sql_path, native_write_restore = true }) end
			end
			return result, reason, number
		end
		return proxy
	end
	local state = { LOG_DIR = temporary, buffer_events = {}, rich_chunks = {}, today_idx = {}, manifest = {} }
	assert(Manager.init(state) == false, "an incomplete first header must reject public initialization")
	assert(refused and failed_close.native_closed, "the physical failure must execute on the original FILE")
	assert(Writer.get_db() == nil, "header failure must precede SQLite admission")
	assert(request({ op = "stat", path = paths.data_sql_path }) == false, "canonical ledger must remain absent after refusal")
	assert(request({ op = "stat", path = paths.today_log_path }) == false, "journal writer must wait for complete canonical header")
	assert(Manager.init(state) == true, table.concat(errors, " | "))
	local header = assert(original_open(paths.data_sql_path, "rb"))
	local published = assert(header:read("*a")); assert(header:close())
	assert(published == header_bytes, "retry must publish exactly the complete original header")
	Manager.log_app_switch("Editor", "Terminal", 100, "2026-10-26 00:00:00.000")
	Manager.ingest_once()
	local db, rows, duration, outbox = assert(Writer.get_db()), 0, 0, nil
	for row in db:nrows("SELECT COUNT(*) AS n FROM events_app_switch") do rows = row.n end
	for row in db:nrows("SELECT app_time_ms FROM agg_app_day WHERE app='Editor'") do duration = row.app_time_ms end
	for row in db:nrows("SELECT value FROM meta WHERE key='local_data_sql_outbox'") do outbox = row.value end
	assert(rows == 1 and duration == 100 and outbox == "", "healthy retry must publish the real SQLite outbox")
	assert(Manager.stop({ process_exit = true }), table.concat(errors, " | "))
	io.open = original_open
	for _, stream in ipairs(streams) do if io.type(stream) == "file" then assert(stream:close()) end end
	print(Json.encode({ kind = "done", fault_mode = mode, initialized_after_refusal = false, retry_initialized = true,
		raw_rows = rows, duration_ms = duration, outbox_empty = outbox == "", header_bytes = #published,
		failed_write = failed_write, failed_close = failed_close, canonical_absent_after_refusal = true,
		journal_absent_after_refusal = true, limits = "Linux native EFBIG or explicit portable FILE refusal; actual publishers/SQLite, metadata and locks adapted; no Darwin-native pressure claim" }))
end, { fs = physical_fs })
