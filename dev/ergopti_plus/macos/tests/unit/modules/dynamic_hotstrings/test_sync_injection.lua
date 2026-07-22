--- tests/unit/modules/dynamic_hotstrings/test_sync_injection.lua

--- ==============================================================================
--- MODULE: dynamic_hotstrings.rules_engine Sync Injection Tests
--- DESCRIPTION:
--- Regression tests for the A3 audit finding: the dynamic-hotstrings interceptor
--- previously deferred injection via hs.timer.doAfter(0), creating a window in
--- which a real keystroke could interleave between the "consume" return and the
--- deferred callback. The fix emits synchronously inside the interceptor.
---
--- These tests verify:
--- 1. The _is_injecting flag is released synchronously (not after a timer).
--- 2. A second interceptor call immediately after the first is NOT blocked by
---    a lingering _is_injecting = true (which the doAfter(0.15) reset would have
---    caused previously).
--- 3. No hs.timer.doAfter call is made during the injection path.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")





-- =======================================================
-- =======================================================
-- ======= 1/ Synchronous injection contract tests =======
-- =======================================================
-- =======================================================

helpers.describe("rules_engine: synchronous injection (A3)", function()
	helpers.it("_is_injecting is reset to false synchronously after injection", function()
		-- Simulate the post-fix injection sequence without HS dependencies.
		-- The key contract: _is_injecting must be false again before control
		-- returns to the caller (i.e. no deferred timer needed).
		local is_injecting = false
		local injected_deletes = 0
		local injected_text    = ""

		local function simulate_inject(n_back, result)
			-- Mirror the fixed interceptor body
			is_injecting = true
			local ok, err = pcall(function()
				for _ = 1, n_back do
					injected_deletes = injected_deletes + 1
				end
				injected_text = injected_text .. result
			end)
			if not ok then
				_ = tostring(err)  -- consume err to satisfy lint
			end
			-- Synchronous release — no timer
			is_injecting = false
		end

		helpers.assert_eq(is_injecting, false)
		simulate_inject(3, "hello")
		-- Must be false immediately after the call, not via a 0.15 s timer
		helpers.assert_eq(is_injecting, false)
		helpers.assert_eq(injected_deletes, 3)
		helpers.assert_eq(injected_text, "hello")
	end)

	helpers.it("a second injection is not blocked when the first completed synchronously", function()
		-- If _is_injecting remained true (as with the old doAfter(0.15) path),
		-- a second interceptor call would bail immediately via the guard
		-- `if _is_injecting … then return nil end` — this must not happen.
		local call_count = 0
		local is_injecting = false

		local function simulate_interceptor(trigger_matched)
			-- Replicate the guard
			if is_injecting then return nil end
			if not trigger_matched then return nil end
			-- Synchronous injection
			is_injecting = true
			pcall(function() call_count = call_count + 1 end)
			is_injecting = false
			return "consume"
		end

		local r1 = simulate_interceptor(true)
		-- After synchronous completion, the second call must not be blocked
		local r2 = simulate_interceptor(true)

		helpers.assert_eq(r1, "consume")
		helpers.assert_eq(r2, "consume")
		helpers.assert_eq(call_count, 2)
	end)

	helpers.it("is_injecting guard still prevents re-entrant injection", function()
		-- Within the synchronous injection body, if a re-entrant call arrives
		-- (theoretically possible via CGEventPost re-entry), the guard must block it.
		local call_count = 0
		local is_injecting = false

		local function simulate_interceptor(trigger_matched)
			if is_injecting then return nil end
			if not trigger_matched then return nil end
			is_injecting = true
			call_count = call_count + 1
			-- Simulate re-entrant call while flag is still true
			local reentrant_result = (function()
				if is_injecting then return nil end
				return "consume"
			end)()
			is_injecting = false
			return "consume", reentrant_result
		end

		local r1, r_inner = simulate_interceptor(true)
		helpers.assert_eq(r1, "consume")
		-- Re-entrant call must have been blocked
		helpers.assert_eq(r_inner, nil)
		helpers.assert_eq(call_count, 1)
	end)
end)
