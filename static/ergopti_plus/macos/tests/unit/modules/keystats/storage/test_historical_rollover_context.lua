--- tests/unit/modules/keystats/storage/test_historical_rollover_context.lua

--- ==============================================================================
--- MODULE: Historical Rollover Boundary Regression
--- DESCRIPTION:
--- Recognize only canonical committed rollover facts, preserve cache-only outbox
--- ownership, and validate every partition before deleting any derived rows.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.keystats.ledger_append_fixture")
local marker = "-- === day rollover 2026-10-20 -> 2026-10-21 ===\n"

local function value(fn, wanted, replacement)
	for index = 1, math.huge do
		local name, current = debug.getupvalue(fn, index)
		assert(name, "missing production ownership: " .. wanted)
		if name == wanted then
			if replacement ~= nil then debug.setupvalue(fn, index, replacement) end
			return current
		end
	end
end

local function insert(id, text, verb, columns, device)
	return (verb or "INSERT OR IGNORE") .. " INTO events_typing (" .. (columns or "device_id, id, ts, text")
		.. ") VALUES (" .. (device or "'device'") .. ", " .. id .. ", '2026-10-20 12:00:00.000', '"
		.. (text or "x"):gsub("'", "''") .. "');\n"
end

local function batch(sql)
	return "BEGIN TRANSACTION;\n" .. sql .. "COMMIT;\n"
end

local function with_owner(scenario)
	helpers.with_stub_scope({ "modules.keystats.ingest_trace" }, function()
		fixture.with_manager(function(manager, state)
			local export = helpers.load_with_stubs("modules.keystats.export")
			local function strict(suffix)
				return manager._local_ledger_replay_cursor(suffix, 0).trailing_rollover
			end
			local function facts(ledger, device, ids)
				return export._typing_rollover_boundaries(ledger, device or "'device'", ids, strict)
			end
			scenario(facts, manager, state, export)
		end)
	end)
end

local function with_rebuild(scenario)
	with_owner(function(facts, manager, state, export)
		local rebuild = value(manager.ingest_once, "_rebuild_aggregates_from_raw")
		local cutoffs = value(rebuild, "_typing_replay_cutoffs")
		local mark = value(manager.ingest_once, "_mark_aggregate_cache_rebuilt")
		value(cutoffs, "_device_id", "device")
		value(cutoffs, "Export", export)
		local paths = value(cutoffs, "_paths")
		paths.data_sql_path, paths.metrics_dir = "owned/device/data.sql", "owned/"
		state.ledgers, state.raw, state.outbox = {}, {}, ""
		value(cutoffs, "fs", { attributes = function(path)
			local ledger = state.ledgers[path]
			return ledger ~= nil and { size = #ledger } or nil
		end })
		value(cutoffs, "FileSystem", { read = function(path) return state.ledgers[path] end })
		local db = { deletes = 0, statements = {}, context = nil }
		function db:nrows(sql)
			local rows = {}
			local device = sql:find("device_id='foreign'", 1, true) and "foreign" or "device"
			local ids = state.raw[device] or {}
			if sql:find("local_data_sql_outbox", 1, true) then rows = { { value = state.outbox } }
			elseif sql:find("SELECT DISTINCT device_id", 1, true) then
				for name in pairs(state.raw) do rows[#rows + 1] = { device_id = name } end
			elseif sql:find("SELECT MAX(id)", 1, true) then
				local maximum = nil
				for _, id in ipairs(ids) do maximum = math.max(maximum or id, id) end
				rows = { { max_id = maximum } }
			elseif sql:find("FROM events_typing", 1, true) then
				local lower, upper = tonumber(sql:match(" AND id>(%d+)")), tonumber(sql:match(" AND id<=(%d+)"))
				for _, id in ipairs(ids) do
					if (not lower or id > lower) and (not upper or id <= upper) then
						rows[#rows + 1] = { id = id, ts = "2026-10-21 00:00:00.000", app = "Editor", events_json = "[]" }
					end
				end
			end
			local index = 0
			return function() index = index + 1; return rows[index] end
		end
		function db:exec(sql)
			self.statements[#self.statements + 1] = sql
			if sql:match("^DELETE") then self.deletes = self.deletes + 1 end
			if sql:find("WHERE key='ngram_ctx_json'", 1, true) then
				if self.context_refused then return 5 end
				self.context = sql:match("value='(.-)' WHERE")
			end
			return 0
		end
		function db:errmsg() return "owned context refusal" end
		scenario(cutoffs, rebuild, mark, db, state, facts, manager, export)
	end)
end

helpers.describe("historical rollover facts", function()
	helpers.it("separates sparse ids at committed markers without consulting timestamps (historical-rollover-context)", function()
		with_owner(function(facts)
			for _, stamp in ipairs({ "2026-10-21", "2026-10-20", "2026-10-19" }) do
				local ledger = batch(insert(3)) .. marker .. batch(insert(9):gsub("2026%-10%-20", stamp))
				helpers.assert_eq(assert(facts(ledger)).cutoffs, { 3 })
			end
		end)
	end)

	helpers.it("accepts observed producer headers and escaped device literals (historical-rollover-context)", function()
		with_owner(function(facts)
			for _, verb in ipairs({ "INSERT", "INSERT OR IGNORE", "INSERT OR REPLACE" }) do
				local sql = insert(1, "x", verb, "device_id,id,ts,app_category", "'O''Brien'")
				local result = assert(facts(batch(sql) .. marker, "'O''Brien'"))
				helpers.assert_eq(result.cutoffs, { 1 })
			end
		end)
	end)

	helpers.it("ignores marker and INSERT lookalikes inside arbitrary SQL values (historical-rollover-context)", function()
		with_owner(function(facts)
			local text = "quoted ' value\n" .. marker .. "COMMIT;\n" .. insert(99)
			local non_typing = "INSERT INTO events_system (device_id,id,metadata_json) VALUES ('device',8,'events_typing');\n"
			local result = assert(facts(batch(insert(1, text) .. non_typing) .. marker .. batch(insert(9))))
			helpers.assert_eq(result.cutoffs, { 1 })
		end)
	end)

	helpers.it("rejects internal malformed and torn-suffix reset authority (historical-rollover-context)", function()
		with_owner(function(facts)
			for _, ledger in ipairs({ batch(insert(1) .. marker), batch(insert(1)) .. "-- ordinary\n",
				batch(insert(1)) .. marker .. "BEGIN TRANSACTION;\n",
				batch(insert(1)) .. "-- === day rollover invalid -> 2026-10-21 ===\n" }) do
				helpers.assert_eq(assert(facts(ledger)).cutoffs, {})
			end
		end)
	end)

	helpers.it("handles empty generations repeated markers and id zero (historical-rollover-context)", function()
		with_owner(function(facts)
			local other = "INSERT INTO events_system (device_id,id,action) VALUES ('device',8,'wake');\n"
			local ledger = marker .. batch(insert(0)) .. marker .. batch(other) .. marker
			helpers.assert_eq(assert(facts(ledger)).cutoffs, { 0 })
		end)
	end)

	helpers.it("refuses unsupported typing shapes only when boundaries need their ids (historical-rollover-context)", function()
		with_owner(function(facts)
			local multiple = insert(1):gsub("%);\n$", "),('device',9,'2026-10-21','y');\n")
			for _, sql in ipairs({ multiple, insert(1, "x", nil, "id,device_id,ts,text"),
				"/* unsupported block comment */\n" .. insert(1) }) do
				local value, detail = facts(batch(sql) .. marker)
				helpers.assert_eq(value, nil)
				helpers.assert_true(type(detail) == "string" and detail ~= "")
				helpers.assert_eq(assert(facts(batch(sql))).cutoffs, {}, "markerless legacy continuity remains")
			end
			local lookalike = assert(facts(batch(insert(1)) .. "/*\n" .. marker .. "*/\n" .. batch(insert(9))))
			helpers.assert_eq(lookalike.cutoffs, {}, "block-comment lookalikes retain markerless continuity")
			helpers.assert_eq(lookalike.has_markers, false)
		end)
	end)

	-- An id at or below the last marker's bound is the legacy id-counter restart
	-- (issue #104). It used to be refused, and an append-only ledger never stops
	-- containing it, so every boot re-scanned the whole ledger only to fail again.
	-- The invariant kept: a restart can never authorize a reset; it withdraws them.
	helpers.it("withdraws every reset when ids restart across a true boundary (issue104-id-restart)", function()
		with_owner(function(facts)
			local ledger = batch(insert(4) .. insert(9)) .. marker .. batch(insert(3)) .. marker .. batch(insert(12))
			local result = assert(facts(ledger))
			helpers.assert_eq(result.cutoffs, {}, "id cutoffs cannot separate generations that share ids")
			helpers.assert_eq(result.has_markers, true)
			helpers.assert_eq(result.regression.id, 3)
			helpers.assert_eq(result.regression.bound, 9)
			helpers.assert_eq(ledger:sub(result.regression.at, result.regression.at + 9), "('device',")
			helpers.assert_eq(assert(facts(batch(insert(9) .. insert(3)))).cutoffs, {})
		end)
	end)

	helpers.it("names the refused shape and its byte in the refusal (issue104-id-restart)", function()
		with_owner(function(facts)
			local multiple = insert(1):gsub("%);\n$", "),('device',9,'2026-10-21','y');\n")
			local ledger = batch(multiple) .. marker
			local _, detail = facts(ledger)
			local at = tonumber(detail:match("multi%-row typing INSERT at byte (%d+)%)$"))
			helpers.assert_true(at ~= nil, detail)
			helpers.assert_eq(ledger:sub(at, at + 9), "('device',")
		end)
	end)
end)

helpers.describe("historical rebuild ownership", function()
	helpers.it("refuses a true marker after a block-contained BEGIN before deleting any rows (historical-rollover-context)", function()
		with_rebuild(function(cutoffs, rebuild, _, db, state, facts)
			local ledger = batch(insert(1)) .. "/*\nBEGIN TRANSACTION;\n*/\n" .. marker .. batch(insert(9))
			local result, detail = facts(ledger)
			helpers.assert_eq(result, nil, "a block-contained BEGIN cannot hide the true boundary")
			helpers.assert_contains(detail, "unsupported or ambiguous typing SQL")
			state.raw.device = { 1, 9 }
			state.ledgers["owned/device/data.sql"] = ledger
			helpers.assert_eq(cutoffs(db, "device"), nil)
			helpers.assert_eq(rebuild(db), false)
			helpers.assert_eq(db.deletes, 0)
		end)
	end)

	helpers.it("rebuilds a ledger whose id counter restarted after a rollover (issue104-id-restart)", function()
		with_rebuild(function(cutoffs, rebuild, _, db, state)
			-- The restarted generation's duplicate ids were dropped by INSERT OR IGNORE.
			local ledger = batch(insert(1) .. insert(5)) .. marker .. batch(insert(1) .. insert(2) .. insert(7))
			state.ledgers["owned/device/data.sql"] = ledger
			state.raw.device = { 1, 2, 5, 7 }
			local walked = 0
			value(rebuild, "Aggregator", { get_ngram_ctx = function() return {} end,
				set_ngram_ctx = function() end, reset_ngram_ctx = function() end,
				set_device_id = function() end, reset_batch = function() end, flush = function() return true end,
				walk_typing = function() walked = walked + 1 end })
			helpers.assert_eq(assert(cutoffs(db, "device")), {})
			helpers.assert_eq(rebuild(db), true, "a legacy restart must not refuse the rebuild forever")
			helpers.assert_true(db.deletes > 0, "the partition was rebuilt")
			helpers.assert_eq(walked, 4, "every retained typing row is replayed")
		end)
	end)

	-- The 22 s startup freeze of issue #104: the recovery ran inside the deferred
	-- keystats start and held every event tap until it returned.
	helpers.it("recovers in budgeted slices while ingest waits (issue104-cooperative-recovery)", function()
		with_rebuild(function(_, rebuild, _, db, state, _, manager)
			local start = value(value(manager.init, "_init"), "_start_aggregate_recovery")
			local slice = value(start, "_run_recovery_slice")
			value(value(start, "_recover_aggregate_cache"), "_sync_foreign_data_sql", function() return {} end)
			local clock = 0
			-- Every clock read spends a whole slice budget, so each pace point yields.
			value(slice, "timer", { absoluteTime = function() clock = clock + 8 * 1000 * 1000; return clock end })
			local pending, cancelled = {}, 0
			value(slice, "TimerScheduler", {
				after = function(_, fn)
					local handle = { timer = {}, fn = fn }
					pending[#pending + 1] = handle
					return handle, true
				end,
				cancel = function(handle) handle.timer = nil; cancelled = cancelled + 1; return true end,
			})
			local walked = 0
			value(rebuild, "Aggregator", { get_ngram_ctx = function() return {} end,
				set_ngram_ctx = function() end, reset_ngram_ctx = function() end,
				set_device_id = function() end, reset_batch = function() end, flush = function() return true end,
				walk_typing = function() walked = walked + 1 end })
			local ids, sql = {}, {}
			for id = 1, 300 do ids[#ids + 1] = id; sql[#sql + 1] = insert(id) end
			state.raw.device = ids
			state.ledgers["owned/device/data.sql"] = batch(table.concat(sql)) .. marker

			start(db)
			helpers.assert_eq(manager.is_recovering(), true, "a large recovery must yield before init returns")
			helpers.assert_true(walked < 300, "the first slice must not walk the whole cache")
			helpers.assert_eq(manager.ingest_once(), false, "ingest waits while the recovery owns the aggregator")
			local slices = 1
			while manager.is_recovering() do
				local handle = table.remove(pending, 1)
				assert(handle, "a yielded recovery must own its next slice timer")
				handle.timer = nil
				handle.fn()
				slices = slices + 1
				assert(slices < 10000, "recovery never ended")
			end
			helpers.assert_eq(walked, 300, "every raw row is replayed across the slices")
			helpers.assert_true(slices > 2, "the recovery ran in several slices")
			helpers.assert_true(db.statements[#db.statements] == "COMMIT;", "the revision mark committed")

			-- A stop in the middle abandons the walk and its exact timer.
			walked = 0
			start(db)
			helpers.assert_eq(manager.is_recovering(), true)
			local cancel = value(value(manager.init, "_rollback_failed_init"), "_release_failed_init_resources")
			helpers.assert_eq(value(cancel, "_cancel_aggregate_recovery")(), true)
			helpers.assert_eq(manager.is_recovering(), false)
			helpers.assert_eq(cancelled, 1, "the pending slice timer is cancelled")
		end)
	end)

	-- The 5.3 s hold of the 2026-10-27 field session: one recovery slice deleted a
	-- whole device partition of derived rows in a single transaction.
	helpers.it("deletes derived rows in bounded committed batches between pace points (field-recovery-delete-batches)", function()
		with_rebuild(function(_, rebuild, _, db, state, _, manager)
			local start = value(value(manager.init, "_init"), "_start_aggregate_recovery")
			local slice = value(start, "_run_recovery_slice")
			value(value(start, "_recover_aggregate_cache"), "_sync_foreign_data_sql", function() return {} end)
			local clock = 0
			value(slice, "timer", { absoluteTime = function() clock = clock + 8 * 1000 * 1000; return clock end })
			local pending = {}
			value(slice, "TimerScheduler", {
				after = function(_, fn)
					local handle = { timer = {}, fn = fn }
					pending[#pending + 1] = handle
					return handle, true
				end,
				cancel = function(handle) handle.timer = nil; return true end,
			})
			value(rebuild, "Aggregator", { get_ngram_ctx = function() return {} end,
				set_ngram_ctx = function() end, reset_ngram_ctx = function() end,
				set_device_id = function() end, reset_batch = function() end, flush = function() return true end,
				walk_typing = function() end })
			-- The first derived table holds more than a batch, and still does after
			-- three batches: one probe finds it large, three find rows left over.
			local left_over_probes = 4
			local nrows = db.nrows
			function db:nrows(sql)
				if sql:find("AS left_over FROM agg_app_day ", 1, true) and left_over_probes > 0 then
					left_over_probes = left_over_probes - 1
					local served = false
					return function() if served then return nil end; served = true; return { left_over = 1 } end
				end
				return nrows(self, sql)
			end
			state.raw.device = { 1 }
			state.ledgers["owned/device/data.sql"] = batch(insert(1)) .. marker

			start(db)
			local slices = 1
			while manager.is_recovering() do
				local handle = table.remove(pending, 1)
				assert(handle, "a yielded recovery must own its next slice timer")
				handle.timer = nil
				handle.fn()
				slices = slices + 1
				assert(slices < 10000, "recovery never ended")
			end
			local bounded, open_deletes = 0, 0
			for _, sql in ipairs(db.statements) do
				if sql:match("^DELETE FROM agg_app_day WHERE rowid IN") then
					bounded = bounded + 1
					open_deletes = open_deletes + 1
					helpers.assert_true(sql:find("LIMIT 100)", 1, true) ~= nil, "a batch is bounded: " .. sql)
					helpers.assert_eq(open_deletes, 1, "one bounded delete per transaction")
				elseif sql == "COMMIT;" then
					open_deletes = 0
				elseif sql:match("^DELETE FROM agg_app_day WHERE device_id") then
					helpers.assert_eq(bounded, 4, "the unbounded delete runs only once the large table is drained")
				end
			end
			helpers.assert_eq(bounded, 4, "the large table is drained in four bounded batches")
			helpers.assert_true(slices >= 4, "a pace point follows every committed batch")
		end)
	end)

	helpers.it("accepts a first pending outbox only when every retained id is covered (historical-rollover-context)", function()
		with_rebuild(function(cutoffs, _, _, db, state)
			state.outbox = batch(insert(1) .. insert(3))
			state.raw.device = { 1, 3 }
			helpers.assert_eq(assert(cutoffs(db, "device")), {})
			state.raw.device = { 1, 2, 3 }
			helpers.assert_eq(cutoffs(db, "device"), nil, "sparse bounds cannot conceal a missing id")
			state.raw.device = {}
			helpers.assert_eq(assert(cutoffs(db, "device")), {}, "fresh empty cache needs no source")
		end)
	end)

	helpers.it("retains a real open range above the canonical trailing marker (historical-rollover-context)", function()
		with_rebuild(function(cutoffs, _, _, db, state)
			state.ledgers["owned/device/data.sql"] = batch(insert(1)) .. marker
			state.raw.device, state.outbox = { 1, 9 }, batch(insert(9))
			helpers.assert_eq(assert(cutoffs(db, "device")), { 1 })
			state.outbox = batch(insert(8))
			helpers.assert_eq(cutoffs(db, "device"), nil)
		end)
	end)

	helpers.it("refuses missing foreign facts and unsafe folder identities (historical-rollover-context)", function()
		with_rebuild(function(cutoffs, _, _, db, state)
			state.raw.foreign = { 1 }
			helpers.assert_eq(cutoffs(db, "foreign"), nil)
			state.raw.device = { 1 }
			helpers.assert_eq(cutoffs(db, "../device"), nil)
			state.ledgers["owned/device/data.sql"] = batch(insert(1)) .. marker
			value(cutoffs, "FileSystem", { read = function() return nil end })
			helpers.assert_eq(cutoffs(db, "device"), nil, "read refusal cannot become markerless continuity")
		end)
	end)

	helpers.it("validates every source before any partition is deleted (historical-rollover-context)", function()
		with_rebuild(function(_, rebuild, _, db, state)
			state.raw.foreign, state.raw.device = { 1 }, { 1 }
			state.ledgers["owned/by_device/foreign/data.sql"] = batch(insert(1, "x", nil, nil, "'foreign'"))
			helpers.assert_eq(rebuild(db), false)
			helpers.assert_eq(db.deletes, 0)
		end)
	end)

	helpers.it("restores local context after a foreign-only boundary replay (historical-rollover-context)", function()
		with_rebuild(function(_, rebuild, mark, db, state)
			state.raw.foreign = { 1 }
			state.ledgers["owned/by_device/foreign/data.sql"] = batch(insert(1, "x", nil, nil, "'foreign'")) .. marker
			local current = { Editor = { cur_word = "local" } }
			local aggregate = { get_ngram_ctx = function() return current end,
				set_ngram_ctx = function(ctx) current = ctx end, reset_ngram_ctx = function() current = {} end,
				set_device_id = function() end, reset_batch = function() end, flush = function() return true end,
				walk_typing = function() current = { foreign = true } end }
			value(rebuild, "Aggregator", aggregate)
			helpers.assert_eq(rebuild(db, { "foreign" }), true)
			helpers.assert_eq(current, { Editor = { cur_word = "local" } })
			helpers.assert_eq(mark(db), true)
			helpers.assert_eq(require("hs.json").decode(db.context), { Editor = { cur_word = "local" } })
		end)
	end)

	helpers.it("commits rebuilt local context with the revision or rolls both back (historical-rollover-context)", function()
		with_rebuild(function(_, _, mark, db)
			value(mark, "Aggregator", { get_ngram_ctx = function() return { Editor = { cur_word = "y" } } end })
			helpers.assert_eq(mark(db), true)
			helpers.assert_eq(require("hs.json").decode(db.context), { Editor = { cur_word = "y" } })
			helpers.assert_eq(db.statements[1], "BEGIN TRANSACTION;")
			helpers.assert_eq(db.statements[#db.statements], "COMMIT;")
			db.statements, db.context_refused = {}, true
			helpers.assert_eq(mark(db), false)
			helpers.assert_eq(db.statements[#db.statements], "ROLLBACK;")
			helpers.assert_eq(#db.statements, 3, "context refusal must precede any version/revision update")
		end)
	end)

	helpers.it("keeps global migration debt after a successful foreign-only refresh (historical-rollover-context)", function()
		with_rebuild(function(_, rebuild, mark, db, state, _, manager, export)
			local json = require("hs.json")
			local current = { Editor = { cur_word = "old-local" } }
			local selected = "device"
			local aggregate = {
				get_ngram_ctx = function() return current end,
				set_ngram_ctx = function(ctx) current = ctx end,
				reset_ngram_ctx = function() current = {} end,
				set_device_id = function(device) selected = device end,
				reset_batch = function() end,
				flush = function() return true end,
				walk_typing = function()
					current = { Editor = { cur_word = selected == "device" and "repaired-local" or "foreign" } }
				end,
			}
			value(rebuild, "Aggregator", aggregate)
			db.revision, db.view_revision = "1", 0
			db.context = json.encode(current)
			local original_rows, original_exec = db.nrows, db.exec
			function db:nrows(sql)
				if sql:find("SELECT value FROM meta WHERE key='aggregate_cache_revision'", 1, true) then
					local pending = true
					return function()
						if pending then pending = false; return { value = self.revision } end
					end
				end
				return original_rows(self, sql)
			end
			function db:exec(sql)
				local rc = original_exec(self, sql)
				if rc == 0 then
					if sql:find("WHERE key='aggregate_cache_revision'", 1, true) then
						self.revision = sql:match("value='(.-)' WHERE")
					elseif sql:find("WHERE key='rev'", 1, true) then
						self.view_revision = self.view_revision + 1
					end
				end
				return rc
			end
			state.raw.device, state.raw.foreign = { 1, 9 }, { 1 }
			-- The real outbox flush must own the fixture's native private path, even when empty.
			value(value(rebuild, "_typing_replay_cutoffs"), "_paths").data_sql_path = state.path
			state.ledgers[state.path] = batch(insert(1)) .. marker .. batch(insert(9))
			state.write(state.ledgers[state.path])
			helpers.assert_eq(rebuild(db), false, "missing foreign authority must refuse the full init rebuild")
			helpers.assert_eq(db.deletes, 0)
			helpers.assert_eq(db.revision, "1")
			local old_context = db.context

			-- Exercise the real ingest callback after the foreign ledger becomes available.
			state.ledgers["owned/by_device/foreign/data.sql"] = batch(insert(1, "x", nil, nil, "'foreign'")) .. marker
			local applied = 0
			export.sync_foreign_data_sql = function(on_applied)
				helpers.assert_eq(on_applied("foreign"), true, "the partial refresh itself must succeed")
				applied = applied + 1
				return { "foreign" }
			end
			value(manager.ingest_once, "SqliteWriter").get_db = function() return db end
			manager.ingest_once()
			helpers.assert_eq(applied, 1)
			helpers.assert_eq(state.reads, 1, "the actual empty-outbox flush must reach the normal EOF read")
			helpers.assert_true(db.deletes > 0, "the foreign partition was really rebuilt")
			helpers.assert_eq(db.revision, "1", "a partial refresh cannot certify the global revision")
			helpers.assert_eq(db.context, old_context, "unvalidated local context cannot be republished")
			helpers.assert_eq(db.view_revision, 1, "a completed partial refresh still invalidates dashboard snapshots")
			helpers.assert_eq(current, { Editor = { cur_word = "old-local" } })

			helpers.assert_eq(rebuild(db), true, "the old revision still permits a complete migration retry")
			helpers.assert_eq(current, { Editor = { cur_word = "repaired-local" } })
			helpers.assert_eq(mark(db), true)
			helpers.assert_eq(db.revision, "2")
			helpers.assert_eq(json.decode(db.context), current)
			helpers.assert_eq(db.view_revision, 2)

			current = { Editor = { cur_word = "current-live" } }
			manager.ingest_once()
			helpers.assert_eq(applied, 2)
			helpers.assert_eq(state.reads, 2)
			helpers.assert_eq(db.revision, "2", "current foreign-only refresh keeps its compatibility mark")
			helpers.assert_eq(json.decode(db.context), current, "current local context keeps normal persistence")
			helpers.assert_eq(db.view_revision, 3)
		end)
	end)
end)
