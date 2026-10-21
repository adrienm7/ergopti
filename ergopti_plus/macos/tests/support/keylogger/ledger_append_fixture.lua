--- tests/support/keylogger/ledger_append_fixture.lua

--- ==============================================================================
--- MODULE: Local Ledger Append Regression Fixture
--- DESCRIPTION:
--- Real manager, append owner, atomic FileSystem publisher and native private
--- files. SQLite's small outbox transaction and refused native receipts are
--- explicit ports; a separate subprocess proof exercises actual OS short writes.
--- ==============================================================================

local helpers = require("tests.helpers")
local M = {}
local OWNED = { "tests.support.file_system_transaction_fixture", "adapters.file_system", "infra.fs_dir",
	"infra.logger", "adapters.ledger_append", "infra.timings", "keylogger.metrics", "modules.keylogger.aggregator",
	"modules.keylogger.export", "modules.keylogger.log_manager", "modules.keylogger.rotation",
	"modules.keylogger.sqlite_writer", "adapters.timer_scheduler", "modules.keylogger.timestamp", "lfs",
	"modules.keylogger.physical_accounting_mode", "modules.keylogger.physical_wire", "keylogger.physical_release",
	"toml_codec.record_scanner", "toml_codec.key_path", "diagnostics.operation_reporter", "infra.toml.reader",
	"toml_codec.reader", "toml_codec.basic_string", "toml_codec.bom", "text_utils", "compat.utf8" }

local function upvalue(fn, wanted)
	for index = 1, math.huge do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then error("missing production ownership: " .. wanted) end
		if name == wanted then return value end
	end
end

--- Runs a scenario with exact process owners restored on every exit.
--- @param scenario function Receives the real manager and private observations.
function M.with_manager(scenario)
	local previous_open, previous_lfs = io.open, rawget(_G, "lfs")
	local root, fs
	local result = table.pack(xpcall(function()
		return helpers.with_stub_scope(OWNED, function()
			rawset(_G, "lfs", nil)
			fs = require("lfs")
			root = os.tmpname(); assert(os.remove(root)); assert(fs.mkdir(root))
			local fixture = require("tests.support.file_system_transaction_fixture")
			return fixture.with_fixture(function(native)
				local state = { path = root .. "/data.sql", reads = 0, close_count = 0, fault = nil, errors = {} }
				local adapter = native.make_adapter()
				state.prefix = "BEGIN TRANSACTION;\nINSERT OR IGNORE INTO events VALUES (0,'old');\nCOMMIT;\n-- durable rollover\n"
				state.batch = "BEGIN TRANSACTION;\nINSERT OR IGNORE INTO events VALUES (1,'new');\nCOMMIT;\n"
				state.outbox = state.batch
				local file = assert(previous_open(state.path, "wb"))
				assert(file:write(state.prefix)); assert(file:close())
				function state.bytes()
					local input = assert(previous_open(state.path, "rb"))
					local bytes = assert(input:read("*a")); assert(input:close()); return bytes
				end
				function state.write(bytes, path)
					local output = assert(previous_open(path or state.path, "wb"))
					assert(output:write(bytes)); assert(output:close())
				end
				local db = {}
				function db:nrows()
					local pending = true
					return function() if pending then pending = false; return { value = state.outbox } end end
				end
				function db:exec(sql)
					if sql == "BEGIN TRANSACTION;" then self.before = state.outbox end
					if sql:find("UPDATE meta SET value=''", 1, true) then state.outbox = "" end
					if sql == "ROLLBACK;" and self.before ~= nil then state.outbox = self.before; self.before = nil end
					if sql == "COMMIT;" then
						if state.clear_refused then return 5 end
						self.before = nil
						if state.clear_uncertain then return 5 end
					end
					return 0
				end
				function db:errmsg() return "owned clear refusal" end
				local logger = helpers.make_logger_stub()
				logger.error = function(_, format, ...) state.errors[#state.errors + 1] = string.format(format, ...) end
				package.loaded["infra.logger"] = logger
				package.loaded["adapters.file_system"] = adapter
				package.loaded["infra.timings"] = { sec = function() return 1 end, ms = function() return 5000 end }
				package.loaded["keylogger.metrics"] = {}
				package.loaded["modules.keylogger.aggregator"] = {}
				local export = helpers.load_with_stubs("modules.keylogger.export")
				package.loaded["modules.keylogger.export"] = {
					sync_foreign_data_sql = function() return {} end,
					_last_complete_batch_offset = export._last_complete_batch_offset,
				}
				package.loaded["modules.keylogger.rotation"] = {
					read_new_entries = function() state.reads = state.reads + 1; return {}, 0, "eof" end,
					get_offset = function() return 0 end,
					rollover = function() state.rotations = (state.rotations or 0) + 1; return true end,
				}
				package.loaded["modules.keylogger.sqlite_writer"] = {
					get_db = function() if not state.closed then return db end end,
					close_db = function() state.closed = true; return true end,
				}
				local manager = helpers.load_with_stubs("modules.keylogger.log_manager")
				upvalue(upvalue(manager.ingest_once, "_flush_local_data_sql_outbox"), "_paths").data_sql_path = state.path
				function state.activate()
					local check = upvalue(manager.day_rollover, "_require_state")
					for index = 1, math.huge do
						local name = debug.getupvalue(check, index)
						assert(name, "missing CoreState owner")
						if name == "_state" then debug.setupvalue(check, index, {}); break end
					end
				end
				function state.restart()
					state.closed = false
					package.loaded["adapters.ledger_append"] = nil
					package.loaded["modules.keylogger.log_manager"] = nil
					manager = helpers.load_with_stubs("modules.keylogger.log_manager")
					upvalue(upvalue(manager.ingest_once, "_flush_local_data_sql_outbox"), "_paths").data_sql_path = state.path
					return manager
				end
				state.files = adapter
				function state.journal()
					local input = assert(previous_open(state.path .. ".append-journal.json", "r"))
					local content = assert(input:read("*a")); assert(input:close())
					return assert(require("hs.json").decode(content))
				end
				io.open = function(path, mode)
					local handle, detail = previous_open(path, mode)
					if handle and path == state.path and mode == "rb" and state.read_fault then
						local proxy = {}
						function proxy:seek(...) return handle:seek(...) end
						function proxy:read(...)
							if state.read_fault == "read throw" then error("native read raised") end
							if state.read_fault == "read nil" then return nil, "native read refused" end
							return handle:read(...)
						end
						function proxy:close()
							state.close_count = state.close_count + 1; assert(handle:close())
							if state.read_fault == "close false" then return false end
							return true
						end
						return proxy
					end
					if not handle or path ~= state.path or (mode ~= "a" and mode ~= "ab") or not state.fault then
						return handle, detail
					end
					local fault, proxy = state.fault, {}
					function proxy:write(bytes)
						if fault:find("write", 1, true) then
							assert(handle:write(bytes:sub(1, 23)))
							if fault == "write throw" then error("native append write raised") end
							if fault == "write foreign" then return true end
							return nil, "native append refused"
						end
						assert(handle:write(bytes)); return self
					end
					function proxy:close()
						state.close_count = state.close_count + 1
						assert(handle:close())
						if fault == "close throw" then error("native append close raised") end
						if fault == "close nil" then return nil, "native append close refused" end
						if fault == "close foreign" then return "closed" end
						return true
					end
					return proxy
				end
				scenario(manager, state)
			end)
		end)
	end, debug.traceback))
	io.open = previous_open
	local cleaned, detail = pcall(function()
		local function remove(path)
			local value = fs.symlinkattributes(path)
			if not value then return end
			if value.mode == "directory" then
				for name in fs.dir(path) do if name ~= "." and name ~= ".." then remove(path .. "/" .. name) end end
				assert(fs.rmdir(path))
			else assert(os.remove(path)) end
		end
		if root then remove(root) end
	end)
	rawset(_G, "lfs", previous_lfs)
	if not result[1] then error(result[2], 0) end
	assert(cleaned, detail)
end

return M
