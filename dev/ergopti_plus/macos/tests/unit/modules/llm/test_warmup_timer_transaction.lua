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
		local after_index = scheduler.after_calls
		local mode = after_modes[after_index] or "commit"
		if mode == "throw" then error("scheduler-after-throw") end
		if mode == "nil" then return nil, false end
		local handle = { active = true, callback = callback, observers = {} }
		scheduler.handles[#scheduler.handles + 1] = handle
		local hook = scheduler.after_hook
		if type(hook) == "function" then
			scheduler.after_hook = nil
			scheduler.after_hook_result = hook(handle)
		end
		return handle, mode == "commit"
	end

	function scheduler.cancel(handle)
		if type(handle) ~= "table" or handle.active ~= true then return true end
		scheduler.cancel_calls = scheduler.cancel_calls + 1
		local cancel_index = scheduler.cancel_calls
		local hook = scheduler.cancel_hook
		if type(hook) == "function" then
			scheduler.cancel_hook = nil
			scheduler.cancel_hook_result = hook(handle)
		end
		local result = cancel_results[cancel_index]
		if result == "throw" then error("scheduler-cancel-throw") end
		if result == "nil" then return nil end
		if result == false then return false end
		handle.active = false
		local observers = handle.observers
		handle.observers = {}
		for _, observer in ipairs(observers) do observer() end
		return true
	end

	function scheduler.onSettled(handle, observer)
		if type(handle) ~= "table" or type(observer) ~= "function" then return false end
		if handle.active ~= true then observer(); return true end
		handle.observers[#handle.observers + 1] = observer
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
			warmup_model = function()
				calls.warmups = calls.warmups + 1
				if type(calls.warmup_hook) == "function" then
					local hook = calls.warmup_hook
					calls.warmup_hook = nil
					calls.warmup_hook_result = hook()
				end
			end,
		},
		get_llm_enabled = function() return enabled end,
	})

	local ok, err = xpcall(function()
		scenario(controller, scheduler, calls)
	end, debug.traceback)
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Runs the controller against the production TimerScheduler adapter while the
--- native timer boundary alone remains injectable.
--- @param stop_mode string|boolean Native stop refusal mode.
--- @param scenario function Scenario receiving controller, scheduler, timer stub, and calls.
local function with_real_scheduler_fixture(stop_mode, scenario)
	local saved = {}
	local saved_hs = _G.hs
	local owned_modules = {
		"adapters.timer_scheduler",
		"hs",
		"infra.logger",
		"infra.timings",
		"modules.llm.warmup_controller",
		"tests.stubs.hs",
	}
	for _, name in ipairs(owned_modules) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end

	local calls = {
		observer_failures = 0,
		on_settled = 0,
		warmups = 0,
	}
	local logger = setmetatable({
		error = function(_, message)
			if tostring(message):find("settlement observer failed", 1, true) then
				calls.observer_failures = calls.observer_failures + 1
			end
		end,
	}, { __index = function() return function() end end })
	package.loaded["infra.logger"] = logger

	local timer_stub = { timers = {} }
	function timer_stub.new(_, callback)
		local native = {
			active = false,
			callback = callback,
			stop_calls = 0,
			stop_mode = "success",
		}
		function native:start()
			self.active = true
			return self
		end
		function native:stop()
			self.stop_calls = self.stop_calls + 1
			if self.stop_mode == "throw" then error("native-stop-refused") end
			if self.stop_mode == "nil" then return nil end
			if self.stop_mode == false then return false end
			self.active = false
			return self
		end
		function native:running() return self.active end
		timer_stub.timers[#timer_stub.timers + 1] = native
		return native
	end
	function timer_stub.secondsSinceEpoch() return 0 end

	local scheduler = helpers.load_with_stubs("adapters.timer_scheduler", {
		timer = timer_stub,
	})
	local production_on_settled = scheduler.onSettled
	scheduler.onSettled = function(handle, observer)
		calls.on_settled = calls.on_settled + 1
		calls.observer_handle_type = type(handle)
		calls.observer_callback_type = type(observer)
		local registered = production_on_settled(handle, observer)
		calls.observer_registered = registered
		return registered
	end
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.logger"] = logger
	package.loaded["infra.timings"] = { sec = function() return 1 end }
	package.loaded["modules.llm.warmup_controller"] = nil

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
		get_llm_enabled = function() return true end,
	})

	local ok, err = xpcall(function()
		scenario(controller, scheduler, timer_stub, calls)
	end, debug.traceback)
	_G.hs = saved_hs
	for _, name in ipairs(owned_modules) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end





-- ==========================================
-- ==========================================
-- ======= 2/ Ownership Regressions =========
-- ==========================================
-- ==========================================

helpers.describe("LLM warmup owns every retry timer transaction", function()
	helpers.it("keeps native acquisition visible to a reentrant PAUSE until exact rollback", function()
		with_fixture({
			after_modes = { "partial" },
			cancel_results = { false, true },
		}, function(controller, scheduler, calls)
			scheduler.after_hook = function()
				return controller.pause_warmup()
			end
			helpers.assert_eq(controller.schedule_warmup_with_retry("start reentry"), false)
			helpers.assert_eq(scheduler.after_hook_result, false,
				"PAUSE must not certify quiescence while native timer start is on-stack")
			helpers.assert_eq(scheduler.handles[1].active, true,
				"a refused rollback must retain the exact partial candidate")
			helpers.assert_eq(calls.warmups, 0)
			helpers.assert_eq(controller.stop(), true)
			helpers.assert_eq(scheduler.handles[1].active, false)
		end)
	end)

	helpers.it("preserves a successor installed by a native cancellation probe", function()
		with_fixture({}, function(controller, scheduler, calls)
			helpers.assert_true(controller.schedule_warmup_with_retry("owner A"))
			scheduler.cancel_hook = function()
				return controller.schedule_warmup_with_retry("owner B")
			end
			helpers.assert_eq(controller.stop(), false,
				"the stale stop may settle A but cannot certify its nested successor B")
			helpers.assert_true(scheduler.cancel_hook_result)
			helpers.assert_eq(scheduler.after_calls, 2)
			helpers.assert_eq(scheduler.handles[2].active, true)
			helpers.assert_eq(calls.warmups, 0)
			helpers.assert_true(controller.stop())
			helpers.assert_eq(scheduler.handles[2].active, false)
		end)
	end)

	helpers.it("keeps a delivered warmup callback owned across reentrant PAUSE", function()
		with_fixture({}, function(controller, scheduler, calls)
			helpers.assert_true(controller.schedule_warmup_with_retry("callback"))
			calls.warmup_hook = function()
				return controller.pause_warmup()
			end
			scheduler.handles[1].callback()
			helpers.assert_eq(calls.warmup_hook_result, false,
				"PAUSE must remain pending until the backend callback frame unwinds")
			helpers.assert_eq(calls.warmups, 1)
			helpers.assert_eq(scheduler.after_calls, 1,
				"the revoked callback must not publish a retry successor")
			helpers.assert_true(controller.pause_warmup(),
				"the PAUSE retry must settle once the callback frame has unwound")
			helpers.assert_true(controller.resume_warmup(),
				"RESUME must restore the callback-owned retry-chain intent")
			helpers.assert_eq(scheduler.after_calls, 2)
			helpers.assert_true(controller.stop())
		end)
	end)

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

	for _, mode in ipairs({ false, "nil", "throw" }) do
		helpers.it("continues once after autonomous timer settlement from "
			.. tostring(mode), function()
			with_fixture({ cancel_results = { mode } }, function(controller, scheduler, calls)
				helpers.assert_eq(controller.schedule_warmup_with_retry("autonomous"), true)
				local owned = scheduler.handles[1]
				owned.callback()
				helpers.assert_eq(calls.warmups, 0,
					"backend work must wait for exact native timer settlement")
				helpers.assert_eq(#owned.observers, 1,
					"the retained continuation must observe the same timer")

				helpers.assert_eq(scheduler.cancel(owned), true)
				helpers.assert_eq(calls.warmups, 1,
					"autonomous settlement must continue the backend attempt once")
				helpers.assert_eq(scheduler.after_calls, 2,
					"the continued attempt must own exactly one retry successor")
				helpers.assert_eq(scheduler.cancel(owned), true)
				helpers.assert_eq(calls.warmups, 1,
					"duplicate settlement cannot repeat backend work")
			end)
		end)
	end

	for _, mode in ipairs({ false, "nil", "throw" }) do
		helpers.it("composes the production settlement observer after "
			.. tostring(mode) .. " refusal (HS-047)", function()
			with_real_scheduler_fixture(mode, function(controller, scheduler, timer_stub, calls)
				helpers.assert_true(controller.schedule_warmup_with_retry("production adapter"))
				helpers.assert_eq(#timer_stub.timers, 1)
				local owned = timer_stub.timers[1]
				owned.stop_mode = mode
				owned.callback()

				helpers.assert_eq(calls.warmups, 0,
					"backend work must wait for exact native settlement")
				helpers.assert_eq(#timer_stub.timers, 1,
					"no fallback may overlap the retained native timer")
				helpers.assert_eq(calls.on_settled, 1,
					"the controller must delegate once to the production observer")
				helpers.assert_eq(calls.observer_handle_type, "table")
				helpers.assert_eq(calls.observer_callback_type, "function")
				helpers.assert_eq(calls.observer_registered, true,
					"valid production observer arguments are an infallible registration")
				helpers.assert_eq(calls.observer_failures, 0)

				owned.stop_mode = "success"
				owned.callback()
				helpers.assert_eq(calls.warmups, 1,
					"settlement must resume exactly one backend attempt")
				helpers.assert_eq(#timer_stub.timers, 2,
					"the resumed attempt must own exactly one successor")
				helpers.assert_eq(scheduler.activeCount(), 1)
				owned.callback()
				helpers.assert_eq(calls.warmups, 1,
					"duplicate native delivery cannot repeat the continuation")
				helpers.assert_eq(#timer_stub.timers, 2)
				helpers.assert_true(controller.stop())
				helpers.assert_eq(scheduler.activeCount(), 0)
			end)
		end)
	end

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
