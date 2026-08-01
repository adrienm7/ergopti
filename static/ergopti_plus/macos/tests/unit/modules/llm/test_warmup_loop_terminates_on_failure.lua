--- tests/unit/modules/llm/test_warmup_loop_terminates_on_failure.lua

--- ==============================================================================
--- MODULE: warmup_controller — retry loop terminates on load failure
--- DESCRIPTION:
--- Regression test that locks down the contract: once core_llm reports a
--- permanent load failure via is_backend_load_failed(), the warmup retry loop
--- must stop arming new hs.timer.doAfter calls.
---
--- Before this behaviour was introduced, try_warmup() would schedule the next
--- retry unconditionally after each warmup attempt. When the backend entered a
--- permanently broken state (bad weights, hung server process) the loop kept
--- creating an unbounded chain of one-shot timers — a timer leak that could
--- never self-resolve.
---
--- APPROACH:
--- 1. Stub lib.timings so the module loads cleanly without the shared TOML file.
--- 2. Inject a custom hs.timer.doAfter that records every scheduling call and
---    captures the callback so we can fire it synchronously.
--- 3. Load warmup_controller via helpers.load_with_stubs with the timer override.
--- 4. Call M.init() with a core_llm stub whose is_backend_load_failed() starts
---    false (backend "still loading") and get_current_model() returns a valid name.
--- 5. Call schedule_warmup_with_retry() — this arms the initial timer (call #1).
--- 6. Fire the initial timer callback: is_backend_load_failed() is still false,
---    so try_warmup() runs a warmup attempt and schedules a retry (call #2).
--- 7. Flip is_backend_load_failed() to true, then fire the retry callback.
--- 8. Assert that no further hs.timer.doAfter call was made (count stays at 2).
--- ==============================================================================

local helpers = require("tests.helpers")


-- =============================================
-- =============================================
-- ======= 1/ Shared Timer Stub ================
-- =============================================
-- =============================================

--- Builds an isolated hs.timer stub that records doAfter calls and lets tests
--- fire callbacks synchronously by index. A fresh instance is created per
--- describe block so call counts never bleed between suites.
--- @return table Stub with doAfter, _calls, _fire(n), and _count().
local function make_timer_stub()
	local stub = {
		_calls = {},  -- { delay, fn } for every doAfter invocation
	}

	function stub.doAfter(delay, fn)
		stub._calls[#stub._calls + 1] = { delay = delay, fn = fn }
		-- Return a minimal timer handle; warmup_controller does not use the handle
		return { stop = function() end }
	end

	--- Fires the Nth scheduled callback (1-based).
	--- @param n number Index into the call list.
	function stub._fire(n)
		local entry = stub._calls[n]
		if entry and entry.fn then entry.fn() end
	end

	--- Returns the number of doAfter calls recorded so far.
	--- @return number Total scheduling calls.
	function stub._count()
		return #stub._calls
	end

	return stub
end


-- ==========================================================
-- ==========================================================
-- ======= 2/ Timings Stub ==================================
-- ==========================================================
-- ==========================================================

-- lib.timings reads a TOML file via the filesystem, which is unavailable in
-- the headless harness. We inject a stub that returns small fixed values so
-- warmup_controller's module-level constants resolve without IO.
local TIMINGS_STUB = {
	sec = function(_, _) return 0.001 end,  -- Near-zero so tests are fast
	ms  = function(_, _) return 1 end,
}


-- =====================================================================
-- =====================================================================
-- ======= 3/ Regression Tests =========================================
-- =====================================================================
-- =====================================================================

helpers.describe("warmup_controller — retry loop terminates after mark_load_failed()", function()

	--- Loads a fresh warmup_controller with the given timer stub wired in.
	--- @param timer_stub table Custom hs.timer replacement.
	--- @return table The loaded warmup_controller module.
	local function load_controller(timer_stub)
		-- Stub lib.timings before requiring the module so the TOML is never read
		package.loaded["infra.timings"] = TIMINGS_STUB
		package.loaded["modules.llm.warmup_controller"] = nil

		local M = helpers.load_with_stubs(
			"modules.llm.warmup_controller",
			{ timer = timer_stub }
		)
		return M
	end

	helpers.it("no additional timer is armed after is_backend_load_failed() returns true", function()
		local timer_stub = make_timer_stub()
		local M = load_controller(timer_stub)

		-- Track whether load failed — starts as a "still loading" backend
		local load_failed = false

		local core_llm_stub = {
			get_current_model   = function() return "gemma-4-e2b-it-mxfp4" end,
			is_backend_ready    = function() return false end,
			is_backend_load_failed = function() return load_failed end,
			get_backend         = function() return "mlx" end,
			get_active_profile  = function() return nil end,
			warmup_model        = function(_, _) end,
		}

		M.init({
			core_llm        = core_llm_stub,
			get_llm_enabled = function() return true end,
		})

		-- Step 1 — schedule_warmup_with_retry arms the initial one-shot timer
		M.schedule_warmup_with_retry("test:init")
		helpers.assert_eq(timer_stub._count(), 1)

		-- Step 2 — fire the initial timer: backend not yet failed, so try_warmup
		-- calls warmup_model and schedules a retry
		timer_stub._fire(1)
		helpers.assert_eq(timer_stub._count(), 2)

		-- Step 3 — mark the backend as permanently failed
		load_failed = true

		-- Step 4 — fire the retry timer: is_backend_load_failed() is now true,
		-- so the loop must return immediately without arming any new timer
		timer_stub._fire(2)
		helpers.assert_eq(timer_stub._count(), 2,
			"no timer must be armed once load has permanently failed")
	end)

	helpers.it("loop halts immediately on first attempt when load already failed at fire time", function()
		local timer_stub = make_timer_stub()
		local M = load_controller(timer_stub)

		-- Backend is already in a failed state before the initial timer fires
		local core_llm_stub = {
			get_current_model   = function() return "broken-model" end,
			is_backend_ready    = function() return false end,
			is_backend_load_failed = function() return true end,
			get_backend         = function() return "mlx" end,
			get_active_profile  = function() return nil end,
			warmup_model        = function(_, _) end,
		}

		M.init({
			core_llm        = core_llm_stub,
			get_llm_enabled = function() return true end,
		})

		-- Only the initial one-shot timer is armed by schedule_warmup_with_retry
		M.schedule_warmup_with_retry("test:already_failed")
		helpers.assert_eq(timer_stub._count(), 1)

		-- Firing it must detect the failed state and stop — no retry scheduled
		timer_stub._fire(1)
		helpers.assert_eq(timer_stub._count(), 1,
			"a pre-failed backend must not schedule any retry at all")
	end)

	helpers.it("loop keeps retrying when load has NOT failed (positive control)", function()
		local timer_stub = make_timer_stub()
		local M = load_controller(timer_stub)

		-- Backend is healthy and never fails — retries must keep accumulating
		local core_llm_stub = {
			get_current_model   = function() return "gemma-4-e2b-it-mxfp4" end,
			is_backend_ready    = function() return false end,
			is_backend_load_failed = function() return false end,
			get_backend         = function() return "mlx" end,
			get_active_profile  = function() return nil end,
			warmup_model        = function(_, _) end,
		}

		M.init({
			core_llm        = core_llm_stub,
			get_llm_enabled = function() return true end,
		})

		M.schedule_warmup_with_retry("test:healthy")
		-- Initial timer (call 1)
		helpers.assert_eq(timer_stub._count(), 1)

		-- Fire initial → warmup attempt + retry (call 2)
		timer_stub._fire(1)
		helpers.assert_eq(timer_stub._count(), 2)

		-- Fire retry → warmup attempt + another retry (call 3)
		timer_stub._fire(2)
		helpers.assert_eq(timer_stub._count(), 3,
			"the loop must keep going when no failure has been declared")
	end)

	helpers.it("loop halts when LLM is disabled, not just on load failure", function()
		local timer_stub = make_timer_stub()
		local M = load_controller(timer_stub)

		local enabled = true
		local core_llm_stub = {
			get_current_model   = function() return "gemma-4-e2b-it-mxfp4" end,
			is_backend_ready    = function() return false end,
			is_backend_load_failed = function() return false end,
			get_backend         = function() return "mlx" end,
			get_active_profile  = function() return nil end,
			warmup_model        = function(_, _) end,
		}

		M.init({
			core_llm        = core_llm_stub,
			get_llm_enabled = function() return enabled end,
		})

		M.schedule_warmup_with_retry("test:disabled")
		helpers.assert_eq(timer_stub._count(), 1)

		-- Disable LLM before the timer fires
		enabled = false
		timer_stub._fire(1)
		-- try_warmup must bail out on the disabled check before arming a retry
		helpers.assert_eq(timer_stub._count(), 1,
			"disabling LLM must stop the retry chain just like a load failure")
	end)

end)
