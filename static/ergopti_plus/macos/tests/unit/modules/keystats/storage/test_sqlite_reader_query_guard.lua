--- tests/unit/modules/keystats/storage/test_sqlite_reader_query_guard.lua

--- ==============================================================================
--- MODULE: sqlite_reader Query Guard Regression Tests (F-MED-28)
--- DESCRIPTION:
--- Every db:nrows() query loop in sqlite_reader.lua (15+ sites across
--- M.read_manifest, M.read_ngrams, M.read_range_split_today) ran unguarded.
--- _open() already caught a failed initial connection, but nothing downstream
--- caught a schema-mismatch or corrupt-db exception raised while STEPPING
--- through a query's results — that exception propagated all the way out of
--- the reader into the metrics-dashboard timer callbacks that call it,
--- surfacing only as an uncaught error in the HS Console.
---
--- FEATURES & RATIONALE:
--- 1. A throwing query must not crash the caller: M.read_manifest /
---    M.read_ngrams / M.read_range_split_today must all return their normal
---    empty-shaped result instead of propagating.
--- 2. A throwing query must log Logger.error so the failure is diagnosable.
--- 3. One throwing table must not prevent OTHER tables' queries from running —
---    each db:nrows() loop is independently guarded.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Stub Setup ==============
-- =====================================
-- =====================================

--- Builds a fake sqlite3 module whose db:nrows() raises for any SQL statement
--- matching `throw_pattern` (a plain substring), and returns a real-ish empty
--- iterator otherwise. exec()/close() are harmless no-ops.
--- @param throw_pattern string|nil Substring; nil means every query throws.
--- @return table A drop-in replacement for hs.sqlite3.
local function make_sqlite_stub(throw_pattern)
	return {
		OK = 0,
		open = function(_path)
			local db = {
				exec = function() return 0 end,
				close = function() end,
				nrows = function(_self, sql)
					if not throw_pattern or sql:find(throw_pattern, 1, true) then
						error("simulated schema mismatch: no such column")
					end
					return function() return nil end -- empty result set
				end,
			}
			return db, nil
		end,
	}
end

--- Loads a fresh sqlite_reader with the given sqlite3 stub and a Logger spy
--- that records every Logger.error(...) call.
--- @param sqlite_stub table Replacement for hs.sqlite3.
--- @return table module, table error_calls
local function load_reader_with(sqlite_stub)
	local error_calls = {}
	package.loaded["infra.logger"] = {
		debug = function() end, trace = function() end, done = function() end,
		info  = function() end, start = function() end, success = function() end,
		warn  = function() end,
		error = function(_log, fmt, ...) table.insert(error_calls, string.format(fmt, ...)) end,
	}
	local reader = helpers.load_with_stubs("modules.keystats.sqlite_reader", { sqlite3 = sqlite_stub })
	return reader, error_calls
end





-- =====================================================================
-- =====================================================================
-- ======= 2/ read_manifest survives a throwing query (F-MED-28) =======
-- =====================================================================
-- =====================================================================

helpers.describe("sqlite_reader — read_manifest survives a throwing db:nrows() (F-MED-28)", function()

	helpers.it("a query that throws does not propagate out of read_manifest", function()
		local reader = load_reader_with(make_sqlite_stub(nil)) -- every query throws
		local ok, result = pcall(function() return reader.read_manifest("/fake/db.sqlite") end)
		helpers.assert_true(ok, "read_manifest must not propagate a db:nrows() exception")
		helpers.assert_eq(type(result), "table", "read_manifest must still return a table")
	end)

	helpers.it("a throwing query logs Logger.error", function()
		local reader, error_calls = load_reader_with(make_sqlite_stub(nil))
		reader.read_manifest("/fake/db.sqlite")
		helpers.assert_true(#error_calls > 0,
			"a schema-mismatch/corrupt-db exception must be logged via Logger.error")
	end)

	helpers.it("a throwing agg_app_day query does not prevent agg_app_day_errors from being read", function()
		-- Only agg_app_day throws; agg_app_day_errors must still populate normally.
		local reader = load_reader_with(make_sqlite_stub("FROM agg_app_day "))
		-- The containment IS the subject. What it was missing: containment that
		-- returned nothing is the same as aborting, from the dashboard's point of view.
		local ok, manifest = pcall(function() return reader.read_manifest("/fake/db.sqlite") end)
		helpers.assert_true(ok, "one throwing table must not abort the whole read_manifest call")
		helpers.assert_true(manifest == nil or type(manifest) == "table",
			"and the tables that did read must still come back")
	end)

end)





-- ===================================================================
-- ===================================================================
-- ======= 3/ read_ngrams survives a throwing query (F-MED-28) =======
-- ===================================================================
-- ===================================================================

helpers.describe("sqlite_reader — read_ngrams survives a throwing db:nrows() (F-MED-28)", function()

	helpers.it("a query that throws does not propagate out of read_ngrams", function()
		local reader = load_reader_with(make_sqlite_stub(nil))
		local ok, result = pcall(function() return reader.read_ngrams("/fake/db.sqlite") end)
		helpers.assert_true(ok, "read_ngrams must not propagate a db:nrows() exception")
		helpers.assert_eq(type(result), "table")
		-- Every expected key must still be present (empty, not nil).
		helpers.assert_eq(type(result.c),  "table")
		helpers.assert_eq(type(result.sc), "table")
		helpers.assert_eq(type(result.kc), "table")
	end)

	helpers.it("a throwing ngram_chars query does not prevent ngram_bigrams from being read", function()
		local seen_bigrams = false
		local sqlite_stub = {
			OK = 0,
			open = function()
				local db = {
					exec = function() return 0 end,
					close = function() end,
					nrows = function(_self, sql)
						if sql:find("FROM ngram_chars ", 1, true) then
							error("simulated failure on ngram_chars")
						end
						if sql:find("FROM ngram_bigrams ", 1, true) then
							seen_bigrams = true
						end
						return function() return nil end
					end,
				}
				return db, nil
			end,
		}
		local reader = load_reader_with(sqlite_stub)
		reader.read_ngrams("/fake/db.sqlite")
		helpers.assert_true(seen_bigrams,
			"ngram_bigrams must still be queried even though ngram_chars threw")
	end)

end)





-- ==============================================================================
-- ==============================================================================
-- ======= 4/ read_range_split_today survives a throwing query (F-MED-28) =======
-- ==============================================================================
-- ==============================================================================

helpers.describe("sqlite_reader — read_range_split_today survives a throwing db:nrows() (F-MED-28)", function()

	helpers.it("a query that throws does not propagate and today/historical stay well-shaped", function()
		local reader = load_reader_with(make_sqlite_stub(nil))
		local ok, result = pcall(function()
			return reader.read_range_split_today("/fake/db.sqlite")
		end)
		helpers.assert_true(ok, "read_range_split_today must not propagate a db:nrows() exception")
		helpers.assert_eq(type(result), "table")
		helpers.assert_eq(type(result.historical), "table")
		helpers.assert_eq(type(result.today), "table")
	end)

end)


helpers.describe("sqlite_reader: semantic media projections and honest query acknowledgement", function()
	local function media_stub(id, refuse)
		return { OK = 0, open = function()
			return { exec = function() return 0 end, close = function() end,
				nrows = function(_, sql)
					local rows = {}
					if sql:find("FROM ngram_media_keys", 1, true) then
						if refuse then error("declared media read refusal") end
						rows = { { date = "2026-10-13", app = "media-editor", media_id = id, c = 2 } }
					elseif sql:find("FROM agg_app_day_media_hold", 1, true) then
						rows = { { date = "2026-10-13", app = "media-editor", media_id = id,
							sum_ms = 535, count = 3, max_ms = 300, tap_count = 2, hold_count = 1 } }
					end
					local index = 0
					return function() index = index + 1; return rows[index] end
				end }
		end }
	end
	helpers.it("projects media-only application days without numeric or typing credit", function()
		local reader = load_reader_with(media_stub("media.play_pause"))
		local manifest, complete = reader.read_manifest("/declared/db.sqlite", "2026-10-13", "2026-10-13")
		helpers.assert_true(complete)
		local app = manifest["2026-10-13"]["media-editor"]
		helpers.assert_eq(app.media_keys["media.play_pause"], 2)
		helpers.assert_eq(app.media_hold["media.play_pause"], { s = 535, n = 3, m = 300, tap = 2, hold = 1 })
		helpers.assert_eq(next(app.kc_hold), nil)
		helpers.assert_eq(app.chars, 0)
	end)
	helpers.it("returns failed acknowledgement for a refused media query while preserving accepted holds", function()
		local reader, errors = load_reader_with(media_stub("media.play_pause", true))
		local manifest, complete = reader.read_manifest("/declared/db.sqlite", "2026-10-13", "2026-10-13")
		helpers.assert_eq(complete, false)
		helpers.assert_eq(manifest["2026-10-13"]["media-editor"].media_hold["media.play_pause"].n, 3)
		helpers.assert_true(#errors > 0)
	end)
	helpers.it("rejects unknown stored media IDs instead of granting projection success", function()
		local reader, errors = load_reader_with(media_stub("media.unknown"))
		local manifest, complete = reader.read_manifest("/declared/db.sqlite", "2026-10-13", "2026-10-13")
		helpers.assert_eq(complete, false)
		local app = manifest["2026-10-13"]["media-editor"]
		if app then
			helpers.assert_eq(next(app.media_keys), nil)
			helpers.assert_eq(next(app.media_hold), nil)
		end
		helpers.assert_true(#errors > 0)
	end)
end)
