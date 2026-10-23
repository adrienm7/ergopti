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

	helpers.it("refuses ids that cross a true boundary backwards (historical-rollover-context)", function()
		with_owner(function(facts)
			helpers.assert_eq(facts(batch(insert(9)) .. marker .. batch(insert(3))), nil)
			helpers.assert_eq(assert(facts(batch(insert(9) .. insert(3)))).cutoffs, {})
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
