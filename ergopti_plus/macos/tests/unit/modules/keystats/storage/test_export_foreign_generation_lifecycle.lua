--- tests/unit/modules/keystats/storage/test_export_foreign_generation_lifecycle.lua

--- ==============================================================================
--- MODULE: Foreign Verification Reader Lifecycle Tests
--- DESCRIPTION:
--- Keeps one actual export reader pending across ingest turns, then invalidates
--- each enumerated source boundary or invokes the real log-manager shutdown.
--- ==============================================================================

local helpers = require("tests.helpers")
local ContentDigest = require("tests.support.content_digest")
local RunloopTimers = require("tests.support.runloop_timers")
local BATCH = "BEGIN TRANSACTION;\nINSERT INTO events VALUES (1);\nCOMMIT;\n"
local PREFIX = BATCH:rep(4000)
local LEDGER = "/generation-lifecycle/by_device/foreign/data.sql"

--- Hold one production verification reader over independently observed native IO.
--- @param check function Receives export and controlled native state.
local function observe(check)
	helpers.with_stub_scope({ "infra.logger", "infra.fs_dir", "modules.keystats.export" }, function()
		local digest = ContentDigest.create()
		local runloop = RunloopTimers.create()
		local state = { ledger_opens = 0, ledger_closes = 0, live = false, sql = {} }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.fs_dir"] = { try_entries = function()
			if state.enumeration_failed then return {}, false, "controlled enumeration refusal" end
			return state.folder_removed and {} or { "foreign" }, true
		end }
		local db = {
			prepare = function() return { bind_values = function() return 0 end,
				step = function() return 101 end, finalize = function() return 0 end } end,
			nrows = function()
				local done = false
				return function()
					if done then return nil end
					done = true
					return { imported_data_sql_size = state.invalid_offset and "invalid" or #PREFIX,
						imported_data_sql_sha256 = digest.for_bytes(PREFIX) }
				end
			end,
			exec = function(_, sql) state.sql[#state.sql + 1] = sql; return 0 end,
		}
		local export = helpers.load_with_stubs("modules.keystats.export", {
			hash = digest,
			timer = runloop.api,
			fs = { attributes = function(path)
				if state.metrics_removed and path == "/generation-lifecycle/" then return nil end
				if state.root_removed and path == "/generation-lifecycle/by_device/" then return nil end
				if state.metadata_removed and path:find("device.json", 1, true) then return nil end
				if state.ledger_removed and path == LEDGER then return nil end
				return { size = state.truncated and 0 or #PREFIX + #BATCH }
			end },
		})
		export.init({ paths = { metrics_dir = "/generation-lifecycle/" }, device_id = "local",
			get_db = function() return not state.database_closed and db or nil end })
		local original_open = io.open
		io.open = function(path, mode)
			if path:find("device.json", 1, true) then
				return { read = function() return '{"device_id":"foreign"}' end, close = function() return true end }
			end
			if path ~= LEDGER then return original_open(path, mode) end
			state.ledger_opens, state.live = state.ledger_opens + 1, true
			local at = 0
			return {
				seek = function(_, _, offset) at = offset; return offset end,
				read = function(_, count)
					local chunk = (PREFIX .. BATCH):sub(at + 1, at + count)
					at = at + #chunk
					return chunk
				end,
				close = function()
					state.ledger_closes = state.ledger_closes + 1
					state.live = false
					return true
				end,
			}
		end
		local ok, err = xpcall(function()
			helpers.assert_eq(export.sync_foreign_data_sql(), {})
			helpers.assert_true(state.live, "fixture must own a partially verified native stream")
			check(export, state)
			export.cleanup()
			runloop.drain()
			helpers.assert_eq(state.sql, {}, "revoked queued pump callbacks cannot apply a stale source")
		end, debug.traceback)
		io.open = original_open
		if not ok then error(err, 0) end
	end)
end

helpers.describe("foreign-ledger-generation-lifecycle", function()
	for _, boundary in ipairs({ "metrics_removed", "root_removed", "folder_removed", "metadata_removed",
		"ledger_removed", "truncated", "enumeration_failed", "database_closed", "invalid_offset" }) do
		helpers.it("foreign-ledger-generation-lifecycle: " .. boundary .. " retires the exact pending reader", function()
			observe(function(export, state)
				state[boundary] = true
				local result, detail = export.sync_foreign_data_sql()
				if boundary == "enumeration_failed" then
					helpers.assert_nil(result)
					helpers.assert_contains(detail, "cannot enumerate")
				else helpers.assert_eq(result, {}) end
				helpers.assert_eq(state.live, false)
				helpers.assert_eq(state.ledger_opens, 1, "retirement cannot acquire a successor")
				helpers.assert_eq(state.ledger_closes, 1)
				helpers.assert_eq(state.sql, {}, "incomplete verification must not reach SQLite")
			end)
		end)
	end
	for _, process_exit in ipairs({ true, false }) do
		helpers.it("foreign-ledger-generation-lifecycle: real log-manager stop closes verification (exit="
			.. tostring(process_exit) .. ")", function()
			observe(function(_, state)
				helpers.with_stub_scope({ "modules.keystats.log_manager", "modules.keystats.sqlite_writer",
					"adapters.ledger_append" }, function()
					local closes = 0
					package.loaded["modules.keystats.sqlite_writer"] = {
						get_db = function() return nil end,
						close_db = function() closes = closes + 1; return true end,
					}
					package.loaded["adapters.ledger_append"] = { cleanup = function() return true end }
					local manager = helpers.load_with_stubs("modules.keystats.log_manager")
					helpers.assert_eq(manager.stop({ process_exit = process_exit }), true)
					helpers.assert_eq(state.live, false)
					helpers.assert_eq(state.ledger_closes, 1)
					helpers.assert_eq(state.sql, {})
					helpers.assert_eq(closes, 1)
				end)
			end)
		end)
	end
end)
