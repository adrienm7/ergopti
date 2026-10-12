--- tests/unit/modules/keylogger/test_export_foreign_partial_batch.lua

--- ==============================================================================
--- MODULE: Regression — foreign data.sql sync applies only complete batches
--- DESCRIPTION:
--- Audit finding F-M3. sync_foreign_data_sql read a foreign device's data.sql from
--- the watermark to EOF and db:exec'd the chunk RAW. A cross-device sync can copy
--- the file mid-append, so the tail can be an orphan "BEGIN TRANSACTION;" + inserts
--- with NO "COMMIT;". Exec'ing that left the connection in an open transaction —
--- which then made the next LOCAL ingest "BEGIN TRANSACTION;" fail ("cannot start a
--- transaction within a transaction") and roll the whole local batch back — and the
--- watermark jumped to the full size, skipping the missing COMMIT forever.
---
--- Fix: apply only through the last complete "COMMIT;" boundary, advance the
--- watermark only to that boundary, roll back on failure, and defensively ROLLBACK
--- before the local ingest BEGIN. The boundary logic is unit-tested here.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.i18n"] = { get = function(k) return k end, t = function(k) return k end }
local Export = helpers.load_with_stubs("modules.keylogger.export")

local BATCH = "\nBEGIN TRANSACTION;\nINSERT OR IGNORE INTO events VALUES (1);\nCOMMIT;\n"

helpers.describe("export._last_complete_batch_offset finds the last whole batch", function()
	helpers.it("returns the newline after COMMIT for a single complete batch", function()
		local off = Export._last_complete_batch_offset(BATCH)
		helpers.assert_true(off > 0, "a complete batch must yield a boundary")
		-- The applicable slice must end exactly at a COMMIT — never include an orphan.
		helpers.assert_eq(BATCH:sub(off - 7, off), "COMMIT;\n")
	end)

	helpers.it("returns the LAST boundary across multiple complete batches", function()
		local two = BATCH .. BATCH
		local off = Export._last_complete_batch_offset(two)
		helpers.assert_eq(off, #two)  -- everything through the final terminator newline
		helpers.assert_eq(two:sub(off - 7, off), "COMMIT;\n")
	end)

	helpers.it("ignores a trailing orphan batch (no COMMIT) — defers it", function()
		-- One complete batch, then a torn half-batch with no COMMIT.
		local torn = BATCH .. "\nBEGIN TRANSACTION;\nINSERT OR IGNORE INTO events VALUES (2);\n"
		local off = Export._last_complete_batch_offset(torn)
		-- Boundary must be at the FIRST batch's COMMIT, NOT the chunk length.
		helpers.assert_true(off < #torn, "must not advance past the orphan trailing batch")
		helpers.assert_eq(torn:sub(off - 7, off), "COMMIT;\n")
		-- The slice we would apply contains NO orphan BEGIN beyond the boundary.
		local applicable = torn:sub(1, off)
		local _, last_begin = applicable:find("BEGIN TRANSACTION;.*", 1)
		helpers.assert_true(select(2, applicable:gsub("BEGIN TRANSACTION;", "")) ==
			select(2, applicable:gsub("COMMIT;", "")),
			"every BEGIN in the applied slice must be matched by a COMMIT")
	end)

	helpers.it("does not mistake COMMIT inside a typed SQL string for a transaction boundary", function()
		local torn = "\nBEGIN TRANSACTION;\nINSERT INTO events VALUES ('typed COMMIT; text');\n"
		helpers.assert_eq(Export._last_complete_batch_offset(torn), 0,
			"only a standalone COMMIT line may make a ledger suffix replayable")
	end)

	helpers.it("does not mistake COMMIT on a newline inside a typed multiline literal", function()
		local torn = "\nBEGIN TRANSACTION;\nINSERT INTO events VALUES ('first line\nCOMMIT;\nlast line');\n"
		helpers.assert_eq(Export._last_complete_batch_offset(torn), 0,
			"a multiline typed value must not make a torn transaction replayable")
	end)

	helpers.it("returns 0 when there is no complete batch yet", function()
		helpers.assert_eq(Export._last_complete_batch_offset("\nBEGIN TRANSACTION;\nINSERT (1);\n"), 0)
		helpers.assert_eq(Export._last_complete_batch_offset(""), 0)
	end)
end)

helpers.describe("foreign sync + local ingest are transaction-safe at source", function()
	helpers.it("export advances the watermark to the COMMIT boundary, not the full size", function()
		-- Selected by a declaration unique to modules/keylogger/export.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M._last_complete_batch_offset")
		helpers.assert_true(src ~= nil, "modules/keylogger/export.lua source must be locatable")
		helpers.assert_true(src:find("_last_complete_batch_offset(chunk)", 1, true) ~= nil,
			"sync must apply only through the last complete batch boundary")
		helpers.assert_true(src:find("watermark + last_commit", 1, true) ~= nil,
			"the watermark must advance only to the applied boundary, not to sz")
	end)

	helpers.it("local ingest defensively rolls back before its BEGIN", function()
		-- Selected by a declaration unique to modules/keylogger/log_manager.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function _mark_aggregate_cache_rebuilt")
		helpers.assert_true(src ~= nil, "modules/keylogger/log_manager.lua source must be locatable")
		local begin_idx = src:find('db:exec("BEGIN TRANSACTION;")', 1, true)
		helpers.assert_true(begin_idx ~= nil, "ingest must BEGIN a transaction")
		local rollback_idx = src:find('db:exec("ROLLBACK;")', 1, true)
		helpers.assert_true(rollback_idx ~= nil and rollback_idx < begin_idx,
			"a defensive ROLLBACK must precede the local ingest BEGIN")
	end)
end)


helpers.describe("keylogger-export-log-privacy", function()
	for _, phase in ipairs({ "invalid", "partial", "derived", "success", "watermark", "rollback" }) do
		helpers.it("keylogger-export-log-privacy: " .. phase .. " preserves sync outcome without logging device identity", function()
			helpers.with_stub_scope({ "infra.logger", "infra.fs_dir", "modules.keylogger.export" }, function()
				local previous_open = io.open
				local ok, err = xpcall(function()
					local identity = "private-foreign-device"
					local folder = "/owned-metrics/by_device/" .. identity .. "/"
					local chunk = phase == "partial" and "BEGIN TRANSACTION;\n" or BATCH
					local messages, statements, bindings = {}, {}, {}
					local logger = helpers.make_logger_stub()
					for _, level in ipairs({ "warn", "debug" }) do
						logger[level] = function(_, format, ...) messages[#messages + 1] = string.format(format, ...) end
					end
					package.loaded["infra.logger"] = logger
					package.loaded["infra.fs_dir"] = {
						try_entries = function(path)
							helpers.assert_eq(path, "/owned-metrics/by_device/")
							return { "local-device", identity }, true
						end,
					}
					io.open = function(path, mode)
						helpers.assert_eq(mode, "r")
						helpers.assert_true(path == folder .. "device.json" or path == folder .. "data.sql")
						return {
							read = function()
								if path == folder .. "data.sql" then return chunk end
								return phase == "invalid" and "invalid-json" or ('{"device_id":"' .. identity .. '"}')
							end,
							seek = function(_, mode, offset) helpers.assert_eq(mode, "set"); helpers.assert_eq(offset, 0) end,
							close = function() return true end,
						}
					end
					local db = {}
					function db:prepare(sql)
						helpers.assert_contains(sql, "INSERT OR IGNORE INTO devices")
						return { bind_values = function(_, ...) bindings = { ... } end,
							step = function() return 0 end, finalize = function() return 0 end }
					end
					function db:nrows(sql)
						helpers.assert_contains(sql, "WHERE device_id='" .. identity .. "'")
						local yielded = false
						return function()
							if phase ~= "invalid" and not yielded then yielded = true; return { imported_data_sql_size = 0 } end
						end
					end
					function db:exec(sql)
						statements[#statements + 1] = sql
						if phase == "rollback" and sql == BATCH then return 1 end
						if phase == "watermark" and sql:find("UPDATE devices", 1, true) then return 1 end
						return 0
					end
					function db:errmsg() return "owned SQL refusal" end
					local export = helpers.load_with_stubs("modules.keylogger.export", {
						fs = { attributes = function() return { size = #chunk } end },
					})
					export.init({ paths = { metrics_dir = "/owned-metrics/" }, device_id = "local-device", get_db = function() return db end })
					local callbacks = 0
					local result, detail = export.sync_foreign_data_sql(function(device_id)
						callbacks = callbacks + 1
						helpers.assert_eq(device_id, identity)
						return phase ~= "derived"
					end)
					helpers.assert_nil(detail)
					helpers.assert_eq(result, phase == "success" and { identity } or {})
					helpers.assert_eq(#messages, 1)
					local expected = {
						invalid = "Foreign sync: skipping invalid device.json.",
						partial = "Foreign sync: no complete batch yet — deferring.",
						derived = "Foreign sync: derived rebuild failed; watermark deferred.",
						success = "Foreign sync: applied " .. #BATCH .. " byte(s).",
						watermark = "Foreign sync: cannot advance watermark: owned SQL refusal.",
					}
					if phase == "rollback" then
						helpers.assert_eq(messages[1]:sub(1, #"Foreign sync rolled back: "), "Foreign sync rolled back: ")
						helpers.assert_contains(messages[1], "owned SQL refusal.")
					else helpers.assert_eq(messages[1], expected[phase]) end
					helpers.assert_nil(messages[1]:find(identity:sub(1, 8), 1, true))
					if phase ~= "invalid" then helpers.assert_eq(bindings[1], identity) end
					local advances = 0
					for _, sql in ipairs(statements) do
						if sql:find("UPDATE devices", 1, true) then
							advances = advances + 1
							helpers.assert_contains(sql, "WHERE device_id='" .. identity .. "'")
						end
					end
					helpers.assert_eq(advances, (phase == "success" or phase == "watermark") and 1 or 0)
					helpers.assert_eq(callbacks, (phase == "derived" or phase == "success" or phase == "watermark") and 1 or 0)
					if phase == "rollback" then helpers.assert_eq(statements[#statements], "ROLLBACK;") end
				end, debug.traceback)
				io.open = previous_open
				if not ok then error(err, 0) end
			end)
		end)
	end
end)
