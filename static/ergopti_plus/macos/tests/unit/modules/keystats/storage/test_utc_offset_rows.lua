--- tests/unit/modules/keystats/storage/test_utc_offset_rows.lua

--- ============================================================================
--- MODULE: Regression — rows in UTC with their recorded offset (KMD-1)
--- DESCRIPTION:
--- Decided by the maintainer on 2026-11-11: a raw row stores its instant in
--- UTC and the local UTC offset in force when it was recorded. The macOS writer
--- converts today.log's local stamp; the raw rebuild reads every row in the
--- local time its user lived, an older Linux row with this Mac's offset and an
--- older macOS row as the local time it already held.
--- ============================================================================

local helpers = require("tests.helpers")
local EmptyLedger = require("tests.support.keystats.absent_ledger_file_system")
local LocalTime = require("metrics.engine.local_time")

local function upvalue(fn, wanted, replacement)
	for index = 1, math.huge do
		local name, current = debug.getupvalue(fn, index)
		assert(name, "missing production ownership: " .. wanted)
		if name == wanted then
			if replacement then debug.setupvalue(fn, index, replacement) end
			return current
		end
	end
end

helpers.describe("keystats: rows in UTC with their recorded offset (utc-offset-rows)", function()
	helpers.it("the writer stores today.log's local stamp as its UTC instant and offset (utc-offset-rows)", function()
		helpers.with_stub_scope({ "infra.logger", "modules.keystats.sqlite_writer" }, function()
			local writer = helpers.load_with_stubs("modules.keystats.sqlite_writer")
			local stamp = "2026-07-01 23:30:00.125"
			local utc, offset = LocalTime.from_local(stamp)
			local sql = writer.build_inserts({ type = "shortcut", timestamp = stamp, app = "Editor", key = "cmd+s" })[1]
			helpers.assert_contains(sql, "'" .. utc .. "', '2026-07-01'")
			helpers.assert_true(sql:match(", " .. offset .. "%);$") ~= nil, "the offset closes the row: " .. sql)
		end)
	end)

	for _, case in ipairs({
		{ os = "darwin", offset = 60, ts = "2026-11-05 22:15:00.000", lived = "2026-11-05 23:15:00.000" },
		{ os = "darwin", ts = "2026-11-05 09:15:00.000", lived = "2026-11-05 09:15:00.000" },
		{ os = "linux", ts = "2026-11-05 09:15:00",
			lived = LocalTime.local_ts("2026-11-05 09:15:00", nil, true, LocalTime.offset_at(os.time())) },
	}) do
		helpers.it("the rebuild reads a " .. case.os .. " row " .. (case.offset and "with" or "without")
			.. " an offset in its lived time (utc-offset-rows)", function()
			helpers.with_stub_scope({
				"infra.logger", "adapters.ledger_append", "modules.keystats.log_manager", "modules.keystats.sqlite_writer",
				"modules.keystats.aggregator", "modules.keystats.rotation", "modules.keystats.export",
				"metrics.engine.metrics", "adapters.file_system", "adapters.timer_scheduler",
			}, function()
				package.loaded["infra.logger"] = helpers.make_logger_stub()
				local seen = {}
				local db = {}
				function db:exec() return 0 end
				function db:errmsg() return "" end
				function db:nrows(sql)
					local rows = {}
					if sql:find("SELECT os FROM devices", 1, true) then rows = { { os = case.os } }
					elseif sql:find("FROM events_system", 1, true) then
						rows = { { ts = case.ts, utc_offset_min = case.offset, action = "wake", metadata_json = "{}", id = 1 } }
					end
					local index = 0
					return function() index = index + 1; return rows[index] end
				end
				package.loaded["modules.keystats.sqlite_writer"] = { get_db = function() return db end }
				package.loaded["modules.keystats.aggregator"] = {
					get_ngram_ctx = function() return {} end, set_device_id = function() end,
					reset_ngram_ctx = function() end, reset_batch = function() end, set_ngram_ctx = function() end,
					settle_contexts = function() return true end,
					walk_system_event = function(entry) seen[#seen + 1] = entry.timestamp end,
				}
				package.loaded["modules.keystats.rotation"] = { read_new_entries = function() return {}, 0, "eof" end }
				package.loaded["modules.keystats.export"] = {
					sync_foreign_data_sql = function(callback) callback("foreign-device"); return {} end,
				}
				local manager = EmptyLedger.load()
				local publish = upvalue(manager.ingest_once, "_publish_rebuilt_partitions")
				upvalue(publish, "_typing_replay_cutoffs", function() return {} end)
				upvalue(publish, "RebuildSnapshot", {
					witness = function() return {} end, same = function() return true end,
					open = function() return { db = db, captured = {} } end,
					publish = function() return true end, close = function() return true end,
				})
				manager.ingest_once()
				helpers.assert_eq(seen, { case.lived })
			end)
		end)
	end
end)

return true
