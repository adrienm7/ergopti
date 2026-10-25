--- tests/unit/modules/keystats/storage/test_export_foreign_pump_cadence.lua

--- ==============================================================================
--- MODULE: Foreign Ledger Foreground Pump Cadence
--- DESCRIPTION:
--- Advances the actual scheduler between ingest ticks. Tight importer retry loops
--- cannot prove that a large source makes progress at the configured ingest cadence.
--- ==============================================================================

local helpers = require("tests.helpers")
local ContentDigest = require("tests.support.content_digest")
local BATCH = "BEGIN TRANSACTION;\nINSERT INTO events VALUES (1);\nCOMMIT;\n"

--- Replays one importer over real timer owners and a deterministic native queue.
--- @param check function Receives the exporter, scheduler and native observations.
local function observe(check)
	helpers.with_stub_scope({ "infra.logger", "infra.fs_dir", "modules.keystats.export",
		"adapters.foreign_ledger_snapshot", "adapters.timer_scheduler", "infra.paced_job" }, function()
		local source = BATCH:rep(8000)
		local h = { now = 0, timers = {}, read_bytes = 0, foreground = 0, watermark = 0, applied = {}, closes = 0 }
		local timer = { absoluteTime = function() return h.now * 1e9 end }
		function timer.new(delay, callback)
			local native = { active = false, delay = delay, callback = callback }
			function native:start()
				self.active, self.due = true, h.now + delay
				h.timers[self] = true
				return self
			end
			function native:stop() self.active = false; h.timers[self] = nil; return self end
			function native:running() return self.active end
			return native
		end
		function h.step()
			local selected
			for native in pairs(h.timers) do
				if native.active and (not selected or native.due < selected.due) then selected = native end
			end
			assert(selected, "the foreground fixture lost every native timer")
			h.now = math.max(h.now, selected.due)
			selected.callback()
			if selected.active then selected.due = h.now + selected.delay end
		end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.fs_dir"] = { try_entries = function() return { "foreign" }, true end }
		local db = {
			prepare = function() return { bind_values = function() return 0 end,
				step = function() return 101 end, finalize = function() return 0 end } end,
			nrows = function()
				local emitted = false
				return function()
					if emitted then return nil end
					emitted = true
					return { imported_data_sql_size = h.watermark, imported_data_sql_sha256 = h.digest }
				end
			end,
			exec = function(_, sql)
				if sql:find("UPDATE devices", 1, true) then
					h.watermark = tonumber(sql:match("imported_data_sql_size=(%d+)"))
					h.digest = sql:match("imported_data_sql_sha256='([0-9a-f]+)'")
				else h.applied[#h.applied + 1] = sql end
				return 0
			end,
		}
		local oracle = ContentDigest.create()
		local export = helpers.load_with_stubs("modules.keystats.export", {
			fs = { attributes = function() return { size = #source } end }, hash = oracle, timer = timer,
		})
		local scheduler = require("adapters.timer_scheduler")
		export.init({ paths = { metrics_dir = "/foreign-pump/metrics/" }, device_id = "local", get_db = function() return db end })
		local original_open = io.open
		io.open = function(path, ...)
			if path:find("device.json", 1, true) then
				return { read = function() return '{"device_id":"foreign"}' end, close = function() return true end }
			end
			if not path:find("data.sql", 1, true) then return original_open(path, ...) end
			local position = 0
			return {
				seek = function(_, mode, offset) helpers.assert_eq(mode, "set"); position = offset; return offset end,
				read = function(_, count)
					helpers.assert_type(count, "number", "physical source reads remain bounded")
					local bytes = source:sub(position + 1, position + count)
					position = position + #bytes
					h.read_bytes = h.read_bytes + #bytes
					-- One native read consumes a slice. The native clock, rather than a
					-- fake PacedJob, decides that the real owner must return to input.
					h.now = h.now + 0.020
					return bytes
				end,
				close = function() h.closes = h.closes + 1; return true end,
			}
		end
		local ok, reason = xpcall(function() check(export, scheduler, h, source, oracle) end, debug.traceback)
		local cleanup_ok, cleaned = pcall(export.cleanup)
		local timers_ok, timers_cleaned = pcall(scheduler.cancelAll)
		io.open = original_open
		if not ok then error(reason, 0) end
		helpers.assert_true(cleanup_ok and cleaned == true, "release the exact source and pump owner")
		helpers.assert_true(timers_ok and timers_cleaned == true, "release the foreground observer")
	end)
end

helpers.describe("foreign ledger foreground pump", function()
	helpers.it("(foreign-ledger-real-cadence) verifies between ingests while foreground timers run", function()
		observe(function(export, scheduler, h, source, oracle)
			local ingest_interval = require("infra.timings").sec("keystats", "ingest_tick_ms")
			local observer, committed = scheduler.every(0.005, function() h.foreground = h.foreground + 1 end)
			helpers.assert_true(committed)
			helpers.assert_type(observer, "table")
			helpers.assert_eq(export.sync_foreign_data_sql(), {})
			local first_bytes = h.read_bytes
			for _ = 1, 80 do h.step() end
			helpers.assert_true(h.foreground > 0, "input and observers must retain intervening turns")
			helpers.assert_true(h.read_bytes > first_bytes,
				"verification must advance between scheduled ingest calls")
			helpers.assert_true(h.now < ingest_interval, "complete this bounded source before the next scheduled ingest")
			helpers.assert_eq(export.sync_foreign_data_sql(), { "foreign" })
			helpers.assert_eq(h.applied, { source })
			helpers.assert_eq(h.watermark, #source)
			helpers.assert_eq(h.digest, oracle.for_bytes(source))
			helpers.assert_eq(h.closes, 1)
		end)
	end)
end)
