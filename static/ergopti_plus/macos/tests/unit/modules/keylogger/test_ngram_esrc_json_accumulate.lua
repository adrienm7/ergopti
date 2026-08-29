--- tests/unit/modules/keylogger/test_ngram_esrc_json_accumulate.lua

--- ==============================================================================
--- MODULE: N-gram Source JSON Accumulation Regression Tests
--- DESCRIPTION:
--- Exercises the production aggregator SQL generator through two flush windows.
--- The database double interprets replacement versus stored-plus-excluded merge
--- semantics, so a direct esrc_json assignment loses the first tick and fails.
--- ==============================================================================

local helpers = require("tests.helpers")




-- =====================================
-- =====================================
-- ======= 1/ Module Loading ===========
-- =====================================
-- =====================================

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

package.loaded["modules.keylogger.export"] = {
	get_native_app_category = function() return "Development" end,
	init = function() end,
}

local active_db = nil
package.loaded["modules.keylogger.sqlite_writer"] = {
	get_db = function() return active_db end,
	init = function() end,
}

local Sql = helpers.load_with_stubs("modules.keylogger.aggregator.sql")
local S = require("modules.keylogger.aggregator.state")
local Core = require("modules.keylogger.aggregator.core")




-- ============================================
-- ============================================
-- ======= 2/ Semantic SQLite Double =========
-- ============================================
-- ============================================

local function copy_map(source)
	local result = {}
	for key, value in pairs(source or {}) do result[key] = value end
	return result
end

local function apply_esrc_upsert(sql, stored, incoming)
	if sql:find("esrc_json%s*=%s*excluded%.esrc_json") then
		return copy_map(incoming)
	end
	if sql:find("esrc_json=COALESCE(esrc_json,'{}')", 1, true) then
		return copy_map(stored)
	end

	local reads_stored = sql:find("json_extract(esrc_json", 1, true)
		or sql:find("json_each(COALESCE(esrc_json", 1, true)
	local reads_incoming = sql:find("json_extract(excluded.esrc_json", 1, true)
		or sql:find("json_each(COALESCE(excluded.esrc_json", 1, true)
	if not (reads_stored and reads_incoming) then
		return nil, "unrecognized esrc_json UPSERT"
	end

	local result = copy_map(stored)
	for key, value in pairs(incoming or {}) do
		result[key] = (result[key] or 0) + value
	end
	return result
end

local function run_flushes(deltas)
	local persisted = {}
	local incoming = nil
	local statements = 0
	local apply_error = nil
	active_db = {
		exec = function(_self, sql)
			if not sql:find("INSERT INTO ngram_bigrams ", 1, true) then return 0 end
			statements = statements + 1
			local next_value
			next_value, apply_error = apply_esrc_upsert(sql, persisted, incoming)
			if not next_value then return 1 end
			persisted = next_value
			return 0
		end,
		errmsg = function() return apply_error or "semantic db failure" end,
	}

	for _, delta in ipairs(deltas) do
		incoming = delta
		Core.reset_batch()
		S.agg_batch.ngram.ngram_bigrams["2024-06-06\1TestApp\1ab"] = {
			c = 1, td = 100, cd = 0, e = 0, esrc = delta,
		}
		helpers.assert_true(Sql.flush(), "the production n-gram UPSERT must commit")
	end
	return persisted, statements
end





-- ====================================================
-- ====================================================
-- ======= 3/ Accumulation Across Flush Windows =======
-- ====================================================
-- ====================================================

helpers.describe("n-gram UPSERT accumulates esrc_json across flush ticks", function()
	helpers.it("sums overlapping and disjoint source keys over two production flushes", function()
		S.initialized = true
		S.device_id = "dev-esrc"
		local persisted, statements = run_flushes({
			{ hotstring = 2, llm = 1 },
			{ hotstring = 3, manual = 4 },
		})

		helpers.assert_true(helpers.deep_equal(persisted, {
			hotstring = 5,
			llm = 1,
			manual = 4,
		}), "esrc_json must retain earlier source counts and sum the current delta")
		helpers.assert_eq(statements, 2,
			"the regression must execute both production flush-window UPSERTs")
	end)

	helpers.it("an empty second delta preserves the stored source distribution", function()
		S.initialized = true
		S.device_id = "dev-esrc-empty"
		local persisted, statements = run_flushes({
			{ hotstring = 2, llm = 1 },
			{},
		})

		helpers.assert_true(helpers.deep_equal(persisted, {
			hotstring = 2,
			llm = 1,
		}), "an empty tick must not replace the stored esrc_json with an empty object")
		helpers.assert_eq(statements, 2)
	end)
end)
