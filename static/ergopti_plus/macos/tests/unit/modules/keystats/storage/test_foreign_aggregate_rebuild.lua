--- tests/unit/modules/keystats/storage/test_foreign_aggregate_rebuild.lua

--- ============================================================================
--- MODULE: Regression — foreign raw sync rebuilds dashboard aggregates
--- DESCRIPTION:
--- Foreign data.sql sync persists canonical events_* rows. The dashboards read
--- agg_* / ngram_* instead, so raw replay alone made cross-device metrics stay
--- stale forever. The raw watermark must only advance after the matching derived
--- partition was rebuilt, and an old cache must run the one-time repair too.
--- ============================================================================

local helpers = require("tests.helpers")
local EmptyLedger = require("tests.support.keystats.absent_ledger_file_system")

-- Two readers, because there are two trees. The driver half is converted below
-- to a SELECTOR so moving or splitting a keystats module cannot turn these
-- invariants into path errors; the shared half is not under the driver root at
-- all, so it goes through the canonical shared-path helper. One reader serving
-- both is what kept this file out of the automated conversion — it would have
-- had to take a selector at three call sites and a path at the fourth.
local function read_shared(relative_path)
	local fh = assert(io.open(helpers.shared(relative_path), "r"))
	local source = fh:read("*a")
	fh:close()
	return source
end

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local source = helpers.read_driver_source(selector)
	return source
end

helpers.describe("keystats: foreign sync rebuilds UI aggregate partitions", function()
	helpers.it("defers the foreign watermark until the derived callback succeeds", function()
		local source = read_source("function M._last_complete_batch_offset") -- modules/keystats/export.lua
		local callback_pos = assert(source:find("pcall(on_applied, entry)", 1, true))
		local watermark_pos = assert(source:find("UPDATE devices SET imported_data_sql_size", callback_pos, true))
		helpers.assert_true(callback_pos < watermark_pos,
			"a failed aggregate rebuild must leave the raw import retryable")
		helpers.assert_true(source:find("return synced_devices", 1, true) ~= nil,
			"the caller must learn when a foreign dashboard update completed")
	end)

	helpers.it("skips an unidentifiable foreign folder instead of rebuilding it forever", function()
		helpers.with_stub_scope({ "infra.logger", "infra.fs_dir", "modules.keystats.export" }, function()
			local ledger_opens, sql_calls, rebuilds, device_rows = 0, 0, 0, 0
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.fs_dir"] = { try_entries = function() return { "foreign" }, true end }
			local export = helpers.load_with_stubs("modules.keystats.export", {
				fs = { attributes = function() return { size = 100 } end },
			})
			export.init({ paths = { metrics_dir = "/unidentifiable/" }, device_id = "local", get_db = function()
				return {
					prepare = function() device_rows = device_rows + 1; return nil end,
					nrows = function() return function() return nil end end,
					exec = function() sql_calls = sql_calls + 1; return 0 end,
				}
			end })
			local original_open = io.open
			io.open = function(path, mode)
				if path == "/unidentifiable/by_device/foreign/device.json" then
					return { read = function() return '{"device_id":"a-different-device"}' end,
						close = function() return true end }
				elseif path == "/unidentifiable/by_device/foreign/data.sql" then
					ledger_opens = ledger_opens + 1
					return nil
				end
				return original_open(path, mode)
			end
			local ok, err = xpcall(function()
				for _ = 1, 2 do
					helpers.assert_eq(export.sync_foreign_data_sql(function() rebuilds = rebuilds + 1 end), {})
				end
				helpers.assert_eq(device_rows, 0, "mismatched metadata cannot publish a device row")
				helpers.assert_eq(ledger_opens, 0, "an unidentified folder cannot authorize any raw ledger read")
				helpers.assert_eq(sql_calls, 0)
				helpers.assert_eq(rebuilds, 0)
			end, debug.traceback)
			io.open = original_open
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("rebuilds only the imported device before invalidating UI snapshots", function()
		local source = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keystats/log_manager.lua
		local callback_pos = assert(source:find("_sync_foreign_data_sql(function(device_id)", 1, true))
		local rebuild_pos = assert(source:find("_rebuild_aggregates_from_raw(db, { device_id })", callback_pos, true))
		local mark_pos = assert(source:find("_mark_aggregate_cache_rebuilt(db)", rebuild_pos, true))
		helpers.assert_true(callback_pos < rebuild_pos and rebuild_pos < mark_pos,
			"foreign rows must be rebuilt and invalidate the DB revision before their watermark advances")
		helpers.assert_true(source:find("DERIVED_DEVICE_TABLES", 1, true) ~= nil,
			"rebuild must clear the old additive aggregate partition before replaying raw rows")
	end)

	helpers.it("migrates existing aggregate caches, not only a brand-new tmp cache", function()
		local manager = read_source("local function _mark_aggregate_cache_rebuilt") -- modules/keystats/log_manager.lua
		local writer = read_source("local function _read_schema_sql") -- modules/keystats/sqlite_writer.lua
		local schema = read_shared("data/db/schema.sql")
		helpers.assert_true(manager:find("aggregate_cache_revision", 1, true) ~= nil,
			"log manager must gate rebuilds with a durable aggregate-cache revision")
		helpers.assert_true(writer:find('{ "aggregate_cache_revision", "0" }', 1, true) ~= nil,
			"upgraded SQLite caches must receive the aggregate-cache revision key")
		helpers.assert_true(schema:find("('aggregate_cache_revision',  '0')", 1, true) ~= nil,
			"fresh SQLite caches must seed the aggregate-cache revision key")
	end)
end)


helpers.describe("keystats-device-log-privacy", function()
	for _, phase in ipairs({ "clear", "replay" }) do
		helpers.it("keystats-device-log-privacy: " .. phase .. " refusal keeps its error without logging the device prefix", function()
			helpers.with_stub_scope({
				"infra.logger", "adapters.ledger_append", "modules.keystats.log_manager", "modules.keystats.sqlite_writer",
				"modules.keystats.aggregator", "modules.keystats.rotation", "modules.keystats.export",
				"keystats.metrics", "adapters.file_system", "adapters.timer_scheduler",
			}, function()
				local messages, queries = {}, {}
				local identity = "private-foreign-device"
				local logger = helpers.make_logger_stub()
				logger.error = function(_, format, ...) messages[#messages + 1] = string.format(format, ...) end
				package.loaded["infra.logger"] = logger
				local db = {}
				function db:exec(sql)
					queries[#queries + 1] = sql
					if phase == "clear" and sql:find("DELETE FROM", 1, true) then return 1 end
					return 0
				end
				function db:errmsg() return "owned database refusal" end
				function db:nrows(sql)
					queries[#queries + 1] = sql
					if phase == "replay" and sql:find("SELECT ts, app, title", 1, true) then
						error("owned replay refusal", 0)
					end
					return function() return nil end
				end
				package.loaded["modules.keystats.sqlite_writer"] = { get_db = function() return db end }
				package.loaded["modules.keystats.aggregator"] = {
					get_ngram_ctx = function() return {} end,
					set_device_id = function() end, reset_ngram_ctx = function() end,
					reset_batch = function() end, set_ngram_ctx = function() end,
				}
				package.loaded["modules.keystats.rotation"] = { read_new_entries = function() return {}, 0, "eof" end }
				local applied, calls = nil, 0
				package.loaded["modules.keystats.export"] = {
					sync_foreign_data_sql = function(callback)
						calls = calls + 1
						applied = callback(identity)
						return {}
					end,
				}
				local manager = EmptyLedger.load()
				manager.ingest_once()
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(applied, false)
				helpers.assert_eq(#messages, 1)
				if phase == "clear" then
					helpers.assert_eq(messages[1]:sub(1, #"Cannot clear derived device rows: "), "Cannot clear derived device rows: ")
					helpers.assert_contains(messages[1], "owned database refusal.")
				else
					helpers.assert_eq(messages[1], "Device aggregate recovery failed: owned replay refusal.")
				end
				helpers.assert_nil(messages[1]:find(identity:sub(1, 8), 1, true))
				helpers.assert_contains(table.concat(queries), "device_id='" .. identity .. "'")
				if phase == "clear" then helpers.assert_contains(table.concat(queries), "ROLLBACK;") end
			end)
		end)
	end
end)
