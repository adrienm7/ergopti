--- tests/unit/modules/keylogger/test_aggregator_sql_flush_retry.lua

--- ==============================================================================
--- MODULE: Aggregator SQL Flush Retry Regression Tests (F-MED-2)
--- DESCRIPTION:
--- Sql.flush() drains the per-tick in-memory accumulator (S.agg_batch) into
--- SQLite via per-row exec() calls. Before this fix, exec() only logged a
--- failure and never propagated it — the caller unconditionally cleared the
--- ENTIRE batch via C.reset_batch() afterwards regardless of which rows
--- actually committed. A single failed row permanently lost that row's
--- aggregate delta forever, since the source keystrokes are never replayed.
---
--- FEATURES & RATIONALE:
--- 1. Success drains the row: when exec() succeeds, the row must be removed
---    from S.agg_batch so it is not double-counted on the next tick.
--- 2. Failure requeues the row: when exec() fails (a locked/corrupt db,
---    simulated by a fake db whose :exec() returns a non-OK code), the row
---    must remain in S.agg_batch untouched so the NEXT flush() retries it
---    with the same accumulated delta.
--- 3. Partial failure is per-row, not per-table: two rows in the same
---    S.agg_batch sub-table can independently succeed/fail — only the
---    failing one survives into the next tick.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Module Loading ===========
-- =====================================
-- =====================================

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

-- export is required by Sql.flush(); category lookup is irrelevant here.
package.loaded["modules.keylogger.export"] = {
	get_native_app_category = function() return "Development" end,
	init = function() end,
}

-- A controllable fake db: exec() consults `_exec_should_fail(sql)` so each
-- test can choose exactly which statements fail, independent of statement
-- ordering (S.agg_batch is a plain Lua table — pairs() iteration order is
-- unspecified — so tests must not depend on "the Nth exec() call" failing).
local _last_db = nil
local function make_fake_db(should_fail_fn)
	local db = {
		exec = function(_self, sql)
			if should_fail_fn and should_fail_fn(sql) then return 1 end -- SQLITE_ERROR
			return 0 -- SQLITE_OK
		end,
		errmsg = function() return "simulated failure" end,
	}
	_last_db = db
	return db
end

package.loaded["modules.keylogger.sqlite_writer"] = {
	get_db = function() return _last_db end,
	init   = function() end,
}

local Sql   = helpers.load_with_stubs("modules.keylogger.aggregator.sql")
local S     = require("modules.keylogger.aggregator.state")
local Core  = require("modules.keylogger.aggregator.core")




-- ================================================
-- ================================================
-- ======= 2/ Success Drains The Batch Row ========
-- ================================================
-- ================================================

helpers.describe("Sql.flush — successful rows are removed from the batch (F-MED-2)", function()

	helpers.it("a single successful agg_app_day row is removed after flush", function()
		S.initialized = true
		S.device_id   = "dev-success"
		Core.reset_batch()
		Core.bump_app_day("2024-01-01", "TestApp", "chars", 10)

		make_fake_db(function(_sql) return false end) -- every exec succeeds

		local flushed = Sql.flush()
		helpers.assert_true(flushed, "flush must confirm that no aggregate delta remains pending")

		local key = "2024-01-01\1TestApp"
		helpers.assert_nil(S.agg_batch.app_day[key],
			"a row whose INSERT/UPSERT succeeded must be removed from the batch — "
			.. "otherwise the next flush would double-count it")
	end)

end)





-- =================================================
-- =================================================
-- ======= 3/ Failure Requeues The Batch Row =======
-- =================================================
-- =================================================

helpers.describe("Sql.flush — failed rows survive into the next tick (F-MED-2)", function()

	helpers.it("a failed agg_app_day row is NOT dropped and keeps its accumulated delta", function()
		S.initialized = true
		S.device_id   = "dev-fail"
		Core.reset_batch()
		Core.bump_app_day("2024-02-02", "FailApp", "chars", 42)

		-- Every agg_app_day INSERT fails (simulated locked/corrupt db).
		make_fake_db(function(sql) return sql:find("INSERT INTO agg_app_day ", 1, true) ~= nil end)

		local flushed = Sql.flush()
		helpers.assert_eq(flushed, false, "flush must report pending rows when an aggregate UPSERT fails")

		local key = "2024-02-02\1FailApp"
		local row = S.agg_batch.app_day[key]
		helpers.assert_true(row ~= nil,
			"a row whose INSERT failed must remain queued in the batch for retry — "
			.. "dropping it here would permanently lose the chars delta forever")
		helpers.assert_eq(row.chars, 42,
			"the failed row's accumulated delta must be preserved unchanged for the retry")
	end)

	helpers.it("a row that keeps failing is retried on every flush() call until it succeeds", function()
		S.initialized = true
		S.device_id   = "dev-retry"
		Core.reset_batch()
		Core.bump_app_day("2024-03-03", "RetryApp", "chars", 7)

		local fail_count = 0
		make_fake_db(function(sql)
			if sql:find("INSERT INTO agg_app_day ", 1, true) then
				fail_count = fail_count + 1
				return fail_count <= 2 -- fail the first two attempts, succeed the third
			end
			return false
		end)

		Sql.flush() -- attempt 1: fails
		helpers.assert_true(S.agg_batch.app_day["2024-03-03\1RetryApp"] ~= nil,
			"row must still be queued after the first failed attempt")

		Sql.flush() -- attempt 2: fails
		helpers.assert_true(S.agg_batch.app_day["2024-03-03\1RetryApp"] ~= nil,
			"row must still be queued after the second failed attempt")

		Sql.flush() -- attempt 3: succeeds
		helpers.assert_nil(S.agg_batch.app_day["2024-03-03\1RetryApp"],
			"row must finally be removed once a retry succeeds")
	end)

end)




-- ========================================================
-- ========================================================
-- ======= 4/ Independent Per-row Success/Failure =========
-- ========================================================
-- ========================================================

helpers.describe("Sql.flush — one row's failure does not affect a sibling row's success (F-MED-2)", function()

	helpers.it("GoodApp succeeds and is dropped; BadApp fails and survives", function()
		S.initialized = true
		S.device_id   = "dev-mixed"
		Core.reset_batch()
		Core.bump_app_day("2024-04-04", "GoodApp", "chars", 5)
		Core.bump_app_day("2024-04-04", "BadApp",  "chars", 9)

		make_fake_db(function(sql)
			return sql:find("BadApp", 1, true) ~= nil
		end)

		Sql.flush()

		helpers.assert_nil(S.agg_batch.app_day["2024-04-04\1GoodApp"],
			"GoodApp's row succeeded and must be removed")
		local bad_row = S.agg_batch.app_day["2024-04-04\1BadApp"]
		helpers.assert_true(bad_row ~= nil, "BadApp's row failed and must remain queued")
		helpers.assert_eq(bad_row.chars, 9)
	end)

end)




-- ========================================================
-- ========================================================
-- ======= 5/ Title Cap Cleanup Coupling (F-MED-2) ========
-- ========================================================
-- ========================================================

helpers.describe("Sql.flush — title rows only drop when both insert and cleanup succeed", function()

	helpers.it("a title row survives if its app-day's cap-cleanup DELETE fails", function()
		S.initialized = true
		S.device_id   = "dev-titles"
		Core.reset_batch()
		local key = "2024-05-05\1TitleApp\1My Window"
		Core.gc(S.agg_batch.titles, key, { date = "2024-05-05", app = "TitleApp", title = "My Window", c = 0, ms = 0 })
		S.agg_batch.titles[key].c = 1

		-- The title INSERT succeeds but the per-app-day cleanup DELETE fails.
		make_fake_db(function(sql)
			return sql:find("DELETE FROM agg_app_day_titles", 1, true) ~= nil
		end)

		Sql.flush()

		helpers.assert_true(S.agg_batch.titles[key] ~= nil,
			"a title row must NOT be dropped when its app-day's cap-cleanup DELETE failed — "
			.. "otherwise the per-app-day title cap silently stops being enforced forever")
	end)

end)





-- ===============================================================
-- ===============================================================
-- ======= 6/ Distribution JSON Accumulates Across Flushes =======
-- ===============================================================
-- ===============================================================

local function copy_map(source)
	local result = {}
	for key, value in pairs(source or {}) do result[key] = value end
	return result
end

local function copy_array(source)
	local result = {}
	for index, value in ipairs(source or {}) do result[index] = value end
	return result
end

local function merge_number_maps(stored, incoming)
	local result = copy_map(stored)
	for key, value in pairs(incoming or {}) do
		result[key] = (result[key] or 0) + value
	end
	return result
end

local function apply_number_map_upsert(sql, column, stored, incoming)
	if sql:find(column .. "%s*=%s*excluded%." .. column) then
		return copy_map(incoming)
	end

	local reads_stored = sql:find("json_extract(" .. column, 1, true)
		or sql:find("json_each(COALESCE(" .. column, 1, true)
	local reads_incoming = sql:find("json_extract(excluded." .. column, 1, true)
		or sql:find("json_each(COALESCE(excluded." .. column, 1, true)
	if reads_stored and reads_incoming then
		return merge_number_maps(stored, incoming)
	end
	return nil, "unrecognized number-map UPSERT for " .. column
end

local function apply_number_array_upsert(sql, column, stored, incoming)
	if sql:find(column .. "%s*=%s*excluded%." .. column) then
		return copy_array(incoming)
	end

	local reads_stored = sql:find("json_each(COALESCE(" .. column, 1, true)
		or sql:find("json_each(" .. column, 1, true)
	local reads_incoming = sql:find("json_each(COALESCE(excluded." .. column, 1, true)
		or sql:find("json_each(excluded." .. column, 1, true)
	if not (reads_stored and reads_incoming) then
		return nil, "unrecognized number-array UPSERT for " .. column
	end

	local result = copy_array(stored)
	for _, value in ipairs(incoming or {}) do result[#result + 1] = value end
	local limit = tonumber(sql:match("LIMIT%s+(%d+)"))
	if limit then
		while #result > limit do result[#result] = nil end
	end
	return result
end

helpers.describe("Sql.flush — distribution JSON survives successive ticks (HS-035)", function()
	helpers.it("sums map buckets and appends bounded session durations across two flushes", function()
		S.initialized = true
		S.device_id = "dev-distributions"

		local persisted = {
			hourly = {},
			min5 = {},
			bursts = {},
			durations = {},
		}
		local incoming = nil
		local statement_counts = {
			hourly = 0,
			min5 = 0,
			bursts = 0,
			durations = 0,
		}

		_last_db = {
			exec = function(_self, sql)
				local target, column, source
				if sql:find("INSERT INTO agg_app_day_hourly ", 1, true) then
					target, column, source = "hourly", "e_buckets_json", incoming.hourly
				elseif sql:find("INSERT INTO agg_app_day_hourly_min5 ", 1, true) then
					target, column, source = "min5", "e_buckets_json", incoming.min5
				elseif sql:find("INSERT INTO agg_app_day_burst ", 1, true) then
					target, column, source = "bursts", "length_buckets_json", incoming.bursts
				elseif sql:find("INSERT INTO agg_app_day_session ", 1, true) then
					target, column, source = "durations", "durations_json", incoming.durations
				else
					return 0
				end

				statement_counts[target] = statement_counts[target] + 1
				local next_value, apply_error
				if target == "durations" then
					next_value, apply_error = apply_number_array_upsert(
						sql, column, persisted[target], source)
				else
					next_value, apply_error = apply_number_map_upsert(
						sql, column, persisted[target], source)
				end
				if not next_value then
					persisted.apply_error = apply_error
					return 1
				end
				persisted[target] = next_value
				return 0
			end,
			errmsg = function() return persisted.apply_error or "semantic db failure" end,
		}

		local function flush_tick(delta)
			incoming = delta
			Core.reset_batch()
			S.agg_batch.hourly["same-hour"] = {
				date = "2024-06-06", app = "TestApp", hour = "10",
				c = 1, e = 1, em = 1, es = 0, e_buckets = delta.hourly,
			}
			S.agg_batch.hourly_min5["same-slot"] = {
				date = "2024-06-06", app = "TestApp", slot = "10:05",
				c = 1, e = 1, es = 0, e_buckets = delta.min5,
			}
			S.agg_batch.bursts["same-app-day"] = {
				date = "2024-06-06", app = "TestApp",
				count_total = 1, max_cpm = 240, max_chars = 20,
				length_buckets = delta.bursts,
				inter_count = 1, inter_sum = 100, inter_sumsq = 10000,
			}
			S.agg_batch.sessions["same-app-day"] = {
				date = "2024-06-06", app = "TestApp",
				count_total = #delta.durations, longest_ms = 3000,
				longest_chars = 20, total_active_ms = 3000,
				durations = delta.durations,
			}
			helpers.assert_true(Sql.flush(), "every synthetic distribution UPSERT must commit")
		end

		local first_durations = {}
		for index = 1, 99 do first_durations[index] = index * 10 end
		flush_tick({
			hourly = { ["1000"] = 2, ["5000"] = 1 },
			min5 = { ["2000"] = 3, ["5000"] = 2 },
			bursts = { ["5"] = 1, ["500+"] = 2 },
			durations = first_durations,
		})
		flush_tick({
			hourly = { ["1000"] = 3, ["2000"] = 4 },
			min5 = { ["2000"] = 4, ["10000"] = 5 },
			bursts = { ["5"] = 4, ["20"] = 3 },
			durations = { 1000, 2000, 3000 },
		})

		helpers.assert_true(helpers.deep_equal(persisted.hourly, {
			["1000"] = 5, ["2000"] = 4, ["5000"] = 1,
		}), "hourly error buckets must sum both flush-window deltas")
		helpers.assert_true(helpers.deep_equal(persisted.min5, {
			["2000"] = 7, ["5000"] = 2, ["10000"] = 5,
		}), "five-minute error buckets must sum both flush-window deltas")
		helpers.assert_true(helpers.deep_equal(persisted.bursts, {
			["5"] = 5, ["20"] = 3, ["500+"] = 2,
		}), "burst-length buckets must sum both flush-window deltas")
		helpers.assert_eq(#persisted.durations, 100,
			"session durations must append across flushes and stay capped by the shared limit")
		helpers.assert_eq(persisted.durations[1], 10,
			"the oldest stored session duration must survive the second flush")
		helpers.assert_eq(persisted.durations[99], 990,
			"all durations from the first flush must survive until the shared cap")
		helpers.assert_eq(persisted.durations[100], 1000,
			"the first new duration must fill the final available slot")
		for target, count in pairs(statement_counts) do
			helpers.assert_eq(count, 2,
				"the test must execute exactly two production UPSERTs for " .. target)
		end
	end)
end)
