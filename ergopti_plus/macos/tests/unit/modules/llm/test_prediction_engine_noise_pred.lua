--- tests/unit/modules/llm/test_prediction_engine_noise_pred.lua

--- ==============================================================================
--- MODULE: prediction_engine is_noise_pred O(N) Regression Tests
--- DESCRIPTION:
--- Source-level guard for the "prediction-engine-noise-pred-on" bug in
--- modules/llm/prediction_engine.lua.
---
--- ROOT CAUSE ENCODED:
--- The local function is_noise_pred() was called on every streaming token.
--- It contained two O(N) operations on the full context buffer:
---   1. buffer:match(".*(%S)") — greedy .* scans from position 1 backwards,
---      O(N) on a 10 k-word context.
---   2. buffer:lower():match("vous") — allocates a full lowercase copy of
---      the entire context buffer on each call.
--- On a 50 k-char context with dozens of tokens per second this saturates
--- one CPU core and can exceed the macOS HID 50 ms latency budget.
---
--- The fix:
---   1. Replace ".*(%S)" with "(%S)%s*$" — anchored-end match, no backtracking.
---   2. Cache buffer:lower() in a local variable before the return expression.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ======================================================================================================
-- ======================================================================================================
-- ======= 1/ is_noise_pred regex is anchored to the buffer end (prediction-engine-noise-pred-on) =======
-- ======================================================================================================
-- ======================================================================================================

helpers.describe("prediction_engine — is_noise_pred regex performance (prediction-engine-noise-pred-on)", function()

	local function read_source()
		-- Selected by a declaration unique to modules/llm/prediction_engine.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function compute_adaptive_debounce")
		helpers.assert_true(src ~= nil, "modules/llm/prediction_engine.lua source must be locatable")
		return src
	end

	helpers.it("source does NOT use greedy buffer:match('.*(%S)') scan", function()
		local src = read_source()
		-- The greedy .* anchor starting at position 1 is O(N) on the full context
		-- buffer — must be replaced with an end-anchored pattern.
		helpers.assert_true(
			src:find([[buffer:match(".*(%S)")]], 1, true) == nil,
			"is_noise_pred must NOT use buffer:match('.*(%S)') — replace with '(%S)%s*$' (prediction-engine-noise-pred-on)"
		)
	end)

	helpers.it("source uses end-anchored buffer:match('(%S)%s*$') for prev_char", function()
		local src = read_source()
		helpers.assert_true(
			src:find([[buffer:match("(%S)%s*$")]], 1, true) ~= nil,
			"is_noise_pred must use buffer:match('(%S)%s*$') to find the last non-space char (prediction-engine-noise-pred-on)"
		)
	end)

	helpers.it("source caches buffer:lower() in a local variable before the return", function()
		local src = read_source()
		-- The cached form assigns buffer:lower() to a local before the return
		-- expression so it is not re-allocated on every condition check.
		helpers.assert_true(
			src:find("buffer_low", 1, true) ~= nil,
			"is_noise_pred must cache buffer:lower() in a local 'buffer_low' variable (prediction-engine-noise-pred-on)"
		)
	end)

	helpers.it("cached buffer_low is used instead of buffer:lower() in the vous check", function()
		local src = read_source()
		-- The vous sentinel must reference the cached variable, not a fresh alloc
		helpers.assert_true(
			src:find([[buffer_low:match("vous")]], 1, true) ~= nil,
			"vous sentinel must use buffer_low, not buffer:lower() (prediction-engine-noise-pred-on)"
		)
	end)

end)
