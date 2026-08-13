--- tests/unit/modules/llm/test_warmup_timer_transaction.lua

--- ==============================================================================
--- MODULE: LLM Warmup Timer Transaction Regression Tests
--- DESCRIPTION:
--- Drives the real warmup controller against adversarial scheduler outcomes so
--- generation fencing cannot hide a live native timer, a refused rollback, or
--- a stale callback that silently starts a second retry chain.
---
--- FEATURES & RATIONALE:
--- 1. Partial Acquisition: Retains an active uncommitted timer for exact retry.
--- 2. Cleanup Debt: Blocks sibling acquisition until native cancel succeeds.
--- 3. Lifecycle Fence: Prevents callbacks queued before stop from warming up.
--- 4. Runtime Gate: Disabled LLM state owns no timer or HTTP warmup attempt.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Adversarial Fixture ============
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.timer_scheduler",
	"infra.logger",
	"infra.timings",
	"modules.llm.warmup_controller",
}

--- Runs one isolated warmup-controller scenario.
--- @param options table|nil Scheduler behavior controls.
--- @param scenario function Scenario receiving controller, scheduler, and calls.
local function with_fixture(options, scenario)
	options = options or {}
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local calls = { warmups = 0 }
	local scheduler = {
		after_calls = 0,
		cancel_calls = 0,
		handles = {},
	}
	local after_modes = options.after_modes or { "commit" }
	local cancel_results = options.cancel_results or {}

	function scheduler.after(_, callback)
		scheduler.after_calls = scheduler.after_calls + 1
		local mode = after_modes[scheduler.after_calls] or "commit"
		if mode == "throw" then error("scheduler-after-throw") end
		if mode == "nil" then return nil, false end
		local handle = { active = true, callback = callback }
		scheduler.handles[#scheduler.handles + 1] = handle
		return handle, mode == "commit"
	end

	function scheduler.cancel(handle)
		if type(handle) ~= "table" or handle.active ~= true then return true end
		scheduler.cancel_calls = scheduler.cancel_calls + 1
		local result = cancel_results[scheduler.cancel_calls]
		if result == "throw" then error("scheduler-cancel-throw") end
		if result == false then return false end
		handle.active = false
		return true
	end

	local function noop() end
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.timings"] = {
		sec = function() return 1 end,
	}

	local enabled = options.enabled ~= false
	local controller = require("modules.llm.warmup_controller")
	controller.init({
		core_llm = {
			get_current_model = function() return "test-model" end,
			is_backend_ready = function() return false end,
			is_backend_load_failed = function() return false end,
			get_backend = function() return "test" end,
			get_active_profile = function() return nil end,
			warmup_model = function() calls.warmups = calls.warmups + 1 end,
		},
		get_llm_enabled = function() return enabled end,
	})

	local ok, err = xpcall(function()
		scenario(controller, scheduler, calls)
	end, debug.traceback)
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end





-- ==========================================
-- ==========================================
-- ======= 2/ Ownership Regressions =========
-- ==========================================
-- ==========================================

helpers.describe("LLM warmup owns every retry timer transaction", function()
	helpers.it("warmup timer retains partial acquisition and blocks a sibling until exact cleanup", function()
		with_fixture({
			after_modes = { "partial", "commit" },
			cancel_results = { false, false, true },
		}, function(controller, scheduler, calls)
			helpers.assert_eq(controller.schedule_warmup_with_retry("partial"), false)
			helpers.assert_eq(scheduler.after_calls, 1)
			helpers.assert_eq(scheduler.cancel_calls, 1)
			helpers.assert_eq(scheduler.handles[1].active, true)

			helpers.assert_eq(controller.schedule_warmup_with_retry("blocked sibling"), false)
			helpers.assert_eq(scheduler.after_calls, 1,
				"cleanup debt must block acquisition of a second native timer")
			helpers.assert_eq(scheduler.cancel_calls, 2)
			helpers.assert_eq(calls.warmups, 0)

			helpers.assert_eq(controller.stop(), true)
			helpers.assert_eq(scheduler.cancel_calls, 3)
			helpers.assert_eq(scheduler.handles[1].active, false)
		end)
	end)

	helpers.it("warmup timer refused cleanup blocks the backend attempt and successor", function()
		with_fixture({ cancel_results = { false, true } }, function(controller, scheduler, calls)
			helpers.assert_eq(controller.schedule_warmup_with_retry("fire"), true)
			scheduler.handles[1].callback()
			helpers.assert_eq(scheduler.cancel_calls, 1)
			helpers.assert_eq(scheduler.after_calls, 1,
				"the retry successor must not overlap refused cleanup debt")
			helpers.assert_eq(calls.warmups, 0,
				"no backend side effect may publish while timer ownership is unresolved")
			helpers.assert_eq(controller.stop(), true)
		end)
	end)

	helpers.it("warmup timer stop fences a callback that was already queued", function()
		with_fixture({}, function(controller, scheduler, calls)
			helpers.assert_eq(controller.schedule_warmup_with_retry("queued"), true)
			local stale_callback = scheduler.handles[1].callback
			helpers.assert_eq(controller.stop(), true)
			stale_callback()
			helpers.assert_eq(calls.warmups, 0)
			helpers.assert_eq(scheduler.after_calls, 1,
				"a callback queued before stop must not create a replacement timer")
		end)
	end)

	helpers.it("warmup timer rejects thrown and nil acquisitions without a phantom chain", function()
		for _, mode in ipairs({ "throw", "nil" }) do
			with_fixture({ after_modes = { mode } }, function(controller, scheduler, calls)
				helpers.assert_eq(controller.schedule_warmup_with_retry(mode), false)
				helpers.assert_eq(scheduler.after_calls, 1)
				helpers.assert_eq(calls.warmups, 0)
				helpers.assert_eq(controller.stop(), true)
			end)
		end
	end)

	helpers.it("warmup timer stays unarmed while the live LLM gate is disabled", function()
		with_fixture({ enabled = false }, function(controller, scheduler, calls)
			helpers.assert_eq(controller.schedule_warmup_with_retry("disabled"), true)
			helpers.assert_eq(scheduler.after_calls, 0)
			helpers.assert_eq(calls.warmups, 0)
		end)
	end)
end)
