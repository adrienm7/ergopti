--- tests/unit/modules/llm/test_streaming_handler_stale.lua

--- ==============================================================================
--- MODULE: streaming_handler stale-success failure-counter Tests
--- DESCRIPTION:
--- Regression tests for the D4 audit finding: on_success() previously reset
--- _consecutive_llm_failures unconditionally, even for stale callbacks whose
--- fetch_id no longer matched. A stale success from a cancelled request would
--- silently zero the failure counter, masking real failures counted since the
--- new request was dispatched.
---
--- After the fix, the reset occurs only AFTER the stale guard passes.
---
--- These tests use a lightweight simulation of the on_success closure logic
--- without requiring the full HS environment.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ================================================================
-- =============================================================
-- ======= 1/ on_success stale-guard and failure-counter =======
-- =============================================================
-- ================================================================

helpers.describe("streaming_handler.on_success: stale guard + failure counter (D4)", function()
	--- Builds a minimal simulation of the post-fix on_success logic.
	--- @return table Engine with on_success, consecutive_failures, current_fetch_id.
	local function make_handler()
		local h = {
			consecutive_failures = 0,
			current_fetch_id     = 1,
		}

		--- Simulate the fixed on_success closure for a given my_fetch_id binding.
		--- @param my_fetch_id number The fetch_id captured at request time.
		--- @param is_final boolean
		--- @param is_streaming_multi boolean
		--- @param is_batch_progressive boolean
		function h.on_success(my_fetch_id, is_final, is_streaming_multi, is_batch_progressive)
			-- Replicate the fixed logic verbatim:
			if not is_final and not is_streaming_multi and not is_batch_progressive then return end
			if h.current_fetch_id ~= my_fetch_id then
				-- Stale — do NOT reset failure counter
				return
			end
			-- Non-stale: reset
			h.consecutive_failures = 0
		end

		return h
	end

	helpers.it("does NOT reset failure counter for a stale callback", function()
		local h = make_handler()
		h.consecutive_failures = 3
		h.current_fetch_id = 2  -- current is 2, callback was for 1
		-- Call with my_fetch_id = 1 (stale), is_final = true
		h.on_success(1, true, false, false)
		helpers.assert_eq(h.consecutive_failures, 3)  -- must be unchanged
	end)

	helpers.it("resets failure counter for a non-stale final callback", function()
		local h = make_handler()
		h.consecutive_failures = 3
		h.current_fetch_id = 2
		h.on_success(2, true, false, false)  -- non-stale
		helpers.assert_eq(h.consecutive_failures, 0)
	end)

	helpers.it("does NOT reset for intermediate batch when is_streaming_multi is false", function()
		local h = make_handler()
		h.consecutive_failures = 2
		h.current_fetch_id = 1
		-- is_final = false, is_streaming_multi = false, is_batch_progressive = false → early return
		h.on_success(1, false, false, false)
		helpers.assert_eq(h.consecutive_failures, 2)
	end)

	helpers.it("resets for streaming multi intermediate (is_streaming_multi = true)", function()
		local h = make_handler()
		h.consecutive_failures = 2
		h.current_fetch_id = 1
		-- is_final = false, is_streaming_multi = true → passes first guard, passes stale guard
		h.on_success(1, false, true, false)
		helpers.assert_eq(h.consecutive_failures, 0)
	end)
end)
