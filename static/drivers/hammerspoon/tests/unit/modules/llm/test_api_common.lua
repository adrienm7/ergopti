--- tests/unit/modules/llm/test_api_common.lua

--- ==============================================================================
--- MODULE: llm.api_common Unit Tests
--- DESCRIPTION:
--- Validates the temperature diversity helper, the dedup statistics accumulator,
--- and insert_prediction's exact-text deduplication contract used by both the
--- MLX and Ollama backend controllers.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")
local ApiCommon = helpers.load_with_stubs("modules.llm.api_common")





-- =====================================
--- ========================================
--- ======= 1/ Diversity Temperature =======
--- ========================================
-- =====================================

helpers.describe("ApiCommon.get_diversity_temperature", function()
	helpers.it("returns base for the first variant", function()
		helpers.assert_eq(ApiCommon.get_diversity_temperature(0.10, 1, 0.30), 0.10)
	end)

	helpers.it("adds delta for variant 2", function()
		local t = ApiCommon.get_diversity_temperature(0.20, 2, 0.30)
		-- base 0.20 (effective_base since >=0.20), idx=2 → +0.30 = 0.50
		helpers.assert_eq(t, 0.50)
	end)

	helpers.it("clamps result to 1.30", function()
		local t = ApiCommon.get_diversity_temperature(0.5, 10, 0.30)
		helpers.assert_eq(t, 1.30)
	end)

	helpers.it("auto-picks delta when not provided (low base)", function()
		local t = ApiCommon.get_diversity_temperature(0.10, 2, nil)
		-- Auto delta = 0.24, effective_base bumped to 0.20, → 0.44
		helpers.assert_true(t > 0.40 and t < 0.50)
	end)

	helpers.it("auto-picks delta when not provided (mid base)", function()
		local t = ApiCommon.get_diversity_temperature(0.30, 2, nil)
		-- Auto delta = 0.18, base 0.30 (>=0.20 already), → 0.48
		helpers.assert_true(t > 0.45 and t < 0.50)
	end)

	helpers.it("auto-picks delta when not provided (high base)", function()
		local t = ApiCommon.get_diversity_temperature(0.50, 2, nil)
		-- Auto delta = 0.12, → 0.62
		helpers.assert_true(t > 0.60 and t < 0.65)
	end)

	helpers.it("treats variant_index < 1 as 1", function()
		helpers.assert_eq(ApiCommon.get_diversity_temperature(0.10, 0, 0.30), 0.10)
		helpers.assert_eq(ApiCommon.get_diversity_temperature(0.10, -5, 0.30), 0.10)
	end)

	helpers.it("falls back to base 0.1 when input is non-numeric", function()
		helpers.assert_eq(ApiCommon.get_diversity_temperature("oops", 1, 0.30), 0.1)
	end)
end)




-- =====================================
-- =====================================
-- ======= 2/ Dedup Stats ===============
-- =====================================
-- =====================================

helpers.describe("ApiCommon.new_dedup_stats", function()
	helpers.it("returns a zeroed stats table", function()
		local s = ApiCommon.new_dedup_stats()
		helpers.assert_eq(s.candidates, 0)
		helpers.assert_eq(s.duplicates, 0)
		helpers.assert_eq(s.kept, 0)
	end)
end)




-- =========================================
-- =========================================
-- ======= 3/ insert_prediction ============
-- =========================================
-- =========================================

helpers.describe("ApiCommon.insert_prediction", function()
	helpers.it("inserts into the result list when dedup is on (no dup)", function()
		local results = {}
		local stats = ApiCommon.new_dedup_stats()
		local ok = ApiCommon.insert_prediction(results, { to_type = "abc" }, stats, true, nil, nil)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(stats.kept, 1)
		helpers.assert_eq(stats.candidates, 1)
		helpers.assert_eq(stats.duplicates, 0)
	end)

	helpers.it("rejects an exact duplicate when dedup enabled", function()
		local results = {}
		local stats = ApiCommon.new_dedup_stats()
		ApiCommon.insert_prediction(results, { to_type = "abc" }, stats, true, nil, nil)
		local ok = ApiCommon.insert_prediction(results, { to_type = "abc" }, stats, true, nil, nil)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(stats.duplicates, 1)
		helpers.assert_eq(stats.kept, 1)
	end)

	helpers.it("inserts duplicates when dedup is off", function()
		local results = {}
		local stats = ApiCommon.new_dedup_stats()
		ApiCommon.insert_prediction(results, { to_type = "abc" }, stats, false, nil, nil)
		local ok = ApiCommon.insert_prediction(results, { to_type = "abc" }, stats, false, nil, nil)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(#results, 2)
		helpers.assert_eq(stats.duplicates, 0)
		helpers.assert_eq(stats.kept, 2)
	end)

	helpers.it("returns false on non-table arguments", function()
		helpers.assert_eq(ApiCommon.insert_prediction(nil, {}, nil, true, nil, nil), false)
		helpers.assert_eq(ApiCommon.insert_prediction({}, nil, nil, true, nil, nil), false)
	end)

	helpers.it("treats nil to_type as the empty string for dedup", function()
		local results = {}
		local stats = ApiCommon.new_dedup_stats()
		ApiCommon.insert_prediction(results, {}, stats, true, nil, nil)
		local ok = ApiCommon.insert_prediction(results, {}, stats, true, nil, nil)
		helpers.assert_eq(ok, false)
	end)
end)




-- =========================================
--- =========================================
-- ======= 4/ log_prediction_summary =======
--- =========================================
-- =========================================

helpers.describe("ApiCommon.log_prediction_summary", function()
	helpers.it("does not error when logger is nil", function()
		ApiCommon.log_prediction_summary(nil, "x", "batch", 3, nil, 2)
	end)

	helpers.it("invokes logger.info with formatted summary", function()
		local captured = {}
		local fake_logger = {
			info = function(name, fmt, ...) captured = { name, fmt, ... } end,
		}
		local stats = { candidates = 5, duplicates = 2, kept = 3 }
		ApiCommon.log_prediction_summary(fake_logger, "ns", "batch", 3, stats, 3)
		helpers.assert_eq(captured[1], "ns")
		-- mode, requested, candidates, duplicates, kept
		helpers.assert_eq(captured[3], "batch")
		helpers.assert_eq(captured[4], 3)
		helpers.assert_eq(captured[5], 5)
		helpers.assert_eq(captured[6], 2)
		helpers.assert_eq(captured[7], 3)
	end)
end)




-- =====================================
-- =====================================
-- ======= 5/ Exposed Defaults =========
-- =====================================
-- =====================================

helpers.describe("ApiCommon defaults", function()
	helpers.it("DEFAULT_DEDUPLICATION_ENABLED is a boolean", function()
		helpers.assert_eq(type(ApiCommon.DEFAULT_DEDUPLICATION_ENABLED), "boolean")
	end)
end)




-- =========================================
--- =========================================
-- ======= 6/ Diversity monotonicity =======
--- =========================================
-- =========================================

helpers.describe("ApiCommon.get_diversity_temperature: monotonicity", function()
	helpers.it("temperature never decreases as variant_index grows", function()
		local prev = -1
		for i = 1, 6 do
			local t = ApiCommon.get_diversity_temperature(0.20, i, 0.10)
			helpers.assert_true(t >= prev, "expected monotonic at i=" .. tostring(i))
			prev = t
		end
	end)

	helpers.it("never exceeds 1.30 for any reasonable input", function()
		for i = 1, 50 do
			local t = ApiCommon.get_diversity_temperature(0.50, i, 0.30)
			helpers.assert_true(t <= 1.30)
		end
	end)
end)




-- =========================================
--- =========================================
-- ======= 7/ insert_prediction edge =======
--- =========================================
-- =========================================

helpers.describe("ApiCommon.insert_prediction: edge cases", function()
	helpers.it("works without a stats accumulator", function()
		local results = {}
		local ok = ApiCommon.insert_prediction(results, { to_type = "x" }, nil, true, nil, nil)
		helpers.assert_eq(ok, true)
		helpers.assert_eq(#results, 1)
	end)

	helpers.it("counts every candidate even when rejected", function()
		local results = {}
		local stats = ApiCommon.new_dedup_stats()
		ApiCommon.insert_prediction(results, { to_type = "a" }, stats, true, nil, nil)
		ApiCommon.insert_prediction(results, { to_type = "a" }, stats, true, nil, nil)
		ApiCommon.insert_prediction(results, { to_type = "a" }, stats, true, nil, nil)
		helpers.assert_eq(stats.candidates, 3)
		helpers.assert_eq(stats.kept, 1)
		helpers.assert_eq(stats.duplicates, 2)
	end)

	helpers.it("invokes logger.debug on duplicate when provided", function()
		local results = {}
		local stats = ApiCommon.new_dedup_stats()
		local debug_calls = 0
		local fake_logger = { debug = function() debug_calls = debug_calls + 1 end }
		ApiCommon.insert_prediction(results, { to_type = "x" }, stats, true, fake_logger, "ns")
		ApiCommon.insert_prediction(results, { to_type = "x" }, stats, true, fake_logger, "ns")
		helpers.assert_eq(debug_calls, 1)
	end)
end)
