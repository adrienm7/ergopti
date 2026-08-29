--- tests/unit/modules/gestures/test_recurring_timer_transaction.lua

--- ==============================================================================
--- MODULE: Gesture Recurring-Timer Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the startup-probe and health-check timer modes through the public
--- gesture lifecycle. It proves that mode transitions retain and cancel the
--- exact timer capability, stale callbacks are generation-fenced, and native
--- stop refusal remains retryable instead of becoming an orphaned listener.
---
--- FEATURES & RATIONALE:
--- 1. Two-Mode Coverage: Drives startup-probe to health-check handoff so both
---    recurring-timer acquisition sites execute behaviorally.
--- 2. Adversarial Cleanup: Models stop refusal and partial acquisition after a
---    timer became active, the two cases in which clearing a handle leaks work.
--- 3. Callback Fencing: Manually fires stale callbacks after stop/transition to
---    prove they cannot restart watchers or replace the current timer.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Isolated Runtime Fixture =======
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.timer_scheduler",
	"hs",
	"hs._asm.undocumented.touchdevice",
	"hs.caffeinate.watcher",
	"infra.logger",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.timings",
	"modules.gestures",
	"modules.gestures.actions",
	"modules.gestures.conflicts",
	"modules.gestures.engine",
	"modules.gestures.init",
	"tests.stubs.hs",
}

--- Runs a scenario against a fresh gesture module and restores every global.
--- @param options table|nil Scheduler fault-injection options.
--- @param scenario function Scenario receiving gestures and scheduler fixture.
local function with_fixture(options, scenario)
	options = options or {}
	local saved_modules = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved_modules[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local saved_hs = _G.hs
	local saved_devices = _G.ERGOPTI_TOUCH_DEVICES
	local saved_watchers = _G.ERGOPTI_TOUCH_WATCHERS
	local saved_sleep = _G.ERGOPTI_SLEEP_WATCHER
	local saved_primer = _G.ERGOPTI_GESTURE_PRIMER
	local saved_first_frame = _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub
	_G.ERGOPTI_TOUCH_DEVICES = {}
	_G.ERGOPTI_TOUCH_WATCHERS = {}
	_G.ERGOPTI_SLEEP_WATCHER = nil
	_G.ERGOPTI_GESTURE_PRIMER = nil

	local scheduler = {
		handles = {},
		cancel_calls = {},
		primer_handles = {},
		wake_handles = {},
		engine_init_calls = 0,
		engine_stop_calls = 0,
	}
	function scheduler.every(interval_sec, callback)
		local index = #scheduler.handles + 1
		local handle = {
			active = true,
			callback = callback,
			index = index,
			interval_sec = interval_sec,
			stop_refusals = index == 1 and (options.first_stop_refusals or 0) or 0,
		}
		scheduler.handles[index] = handle
		if index == 1 and options.first_partial_acquisition then return handle, false end
		return handle, true
	end
	function scheduler.cancel(handle)
		if type(handle) ~= "table" or handle.active ~= true then return true end
		scheduler.cancel_calls[#scheduler.cancel_calls + 1] = handle
		if handle.stop_refusals > 0 then
			handle.stop_refusals = handle.stop_refusals - 1
			return false
		end
		handle.active = false
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler

	local primer_start_results = options.primer_start_results or {}
	hs_stub.eventtap.new = function(types, callback)
		local creation = #scheduler.primer_handles + 1
		local handle = { types = types, callback = callback, running = false, stop_calls = 0 }
		function handle:start()
			local result = primer_start_results[creation]
			if result == "throw" then error("primer start exploded") end
			if result == false then return false end
			self.running = true
			return self
		end
		function handle:stop()
			self.stop_calls = self.stop_calls + 1
			self.running = false
			return self
		end
		function handle:isEnabled() return self.running end
		scheduler.primer_handles[creation] = handle
		return handle
	end

	local function noop() end
	local function committed() return true end
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.manifest_reader"] = { default_for = function() return false end }
	package.loaded["infra.notifications"] = { notify = noop }
	package.loaded["infra.timings"] = {
		sec = function(_, key)
			if key == "health_check_interval_ms" then return 30 end
			if key == "startup_phase_timeout_ms" then return 10 end
			return 5
		end,
	}
	package.loaded["modules.gestures.actions"] = setmetatable({
		AX_NAMES = {},
		SG_NAMES = {},
		init = committed,
		force_cleanup = committed,
		resume_after_cleanup = committed,
	}, { __index = function() return noop end })
	package.loaded["modules.gestures.engine"] = setmetatable({
		init = function()
			scheduler.engine_init_calls = scheduler.engine_init_calls + 1
			if options.initial_engine_init_refuses
				and scheduler.engine_init_calls == 1 then return false end
			return true
		end,
		stop = function()
			scheduler.engine_stop_calls = scheduler.engine_stop_calls + 1
			return true
		end,
	}, {
		__index = function() return noop end,
	})
	package.loaded["modules.gestures.conflicts"] = setmetatable({}, {
		__index = function() return noop end,
	})
	package.loaded["hs._asm.undocumented.touchdevice"] = { devices = function() return {} end }
	local wake_start_results = options.wake_start_results or {}
	package.loaded["hs.caffeinate.watcher"] = {
		systemDidWake = 1,
		screensDidUnlock = 2,
		new = function(callback)
			local creation = #scheduler.wake_handles + 1
			local handle = { callback = callback, running = false, stop_calls = 0 }
			function handle:start()
				local result = wake_start_results[creation]
				if result == "throw" then error("wake watcher start exploded") end
				if result == false then return false end
				self.running = true
				return self
			end
			function handle:stop()
				self.stop_calls = self.stop_calls + 1
				self.running = false
				return self
			end
			scheduler.wake_handles[creation] = handle
			return handle
		end,
	}

	local gestures = require("modules.gestures.init")
	local ok, err = xpcall(function() scenario(gestures, scheduler) end, debug.traceback)

	_G.hs = saved_hs
	_G.ERGOPTI_TOUCH_DEVICES = saved_devices
	_G.ERGOPTI_TOUCH_WATCHERS = saved_watchers
	_G.ERGOPTI_SLEEP_WATCHER = saved_sleep
	_G.ERGOPTI_GESTURE_PRIMER = saved_primer
	_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = saved_first_frame
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end

	if not ok then error(err, 0) end
end





-- =========================================
-- =========================================
-- ======= 2/ Lifecycle Transactions =======
-- =========================================
-- =========================================

helpers.describe("gestures recurring timers are exact lifecycle transactions", function()
	helpers.it("hands off startup probe to health check and fences the stale probe callback", function()
		with_fixture({}, function(gestures, scheduler)
			helpers.assert_eq(gestures.start(), true, "startup must report a committed recurring timer")
			helpers.assert_eq(#scheduler.handles, 1)
			local startup = scheduler.handles[1]
			helpers.assert_eq(startup.interval_sec, 0.5, "the first recurring timer is the startup probe")
			startup.stop_refusals = 1

			_G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME = true
			startup.callback()
			helpers.assert_eq(#scheduler.handles, 2, "first-frame delivery must arm the health-check timer")
			local health = scheduler.handles[2]
			helpers.assert_eq(health.interval_sec, 30, "the second recurring timer is the health check")
			helpers.assert_eq(startup.active, true,
				"a predecessor stop refusal must stay owned without blocking the new timer")
			helpers.assert_eq(health.active, true)

			health.callback()
			helpers.assert_eq(startup.active, false,
				"the new recurring timer must retry its predecessor's exact cleanup debt")
			startup.callback()
			helpers.assert_eq(#scheduler.handles, 2,
				"a stale startup callback must not replace the current health-check timer")
			helpers.assert_eq(health.active, true)
			helpers.assert_eq(gestures.stop(), true)
			helpers.assert_eq(health.active, false, "module stop must cancel the exact health-check timer")
		end)
	end)

	helpers.it("retains cleanup debt when timer stop refuses and retries the exact handle", function()
		with_fixture({}, function(gestures, scheduler)
			helpers.assert_eq(gestures.start(), true)
			local startup = scheduler.handles[1]
			startup.stop_refusals = 1

			helpers.assert_eq(gestures.stop(), false,
				"stop refusal must be surfaced instead of clearing ownership")
			helpers.assert_eq(startup.active, true, "the exact timer remains owned while cleanup is pending")
			helpers.assert_eq(gestures.stop(), true,
				"a later teardown must retry the exact retained timer")
			helpers.assert_eq(startup.active, false,
				"the repeated stop must settle the original timer capability")
			helpers.assert_eq(#scheduler.handles, 1, "cleanup retry must not start a replacement after stop")
		end)
	end)

	helpers.it("contains a partial recurring-timer acquisition until teardown can retry it", function()
		with_fixture({ first_partial_acquisition = true, first_stop_refusals = 2 },
			function(gestures, scheduler)
				helpers.assert_eq(gestures.start(), false,
					"an active-then-failed timer start must fail the gesture transaction")
				local partial = scheduler.handles[1]
				helpers.assert_eq(partial.active, true,
					"cleanup refusal must retain the exact partially-started capability")
				helpers.assert_eq(#scheduler.cancel_calls, 2,
					"acquisition rollback and internal stop must both retry the same handle")

				helpers.assert_eq(gestures.stop(), true,
					"a later teardown must retry cleanup of the partially-started timer")
				helpers.assert_eq(partial.active, false,
					"the exact partial acquisition must be settled on retry")
				helpers.assert_eq(#scheduler.handles, 1,
					"cleanup retry must never resurrect discovery")
		end)
	end)

	helpers.it("retries an engine that refused module-load initialization", function()
		with_fixture({ initial_engine_init_refuses = true }, function(gestures, scheduler)
			helpers.assert_eq(scheduler.engine_init_calls, 1,
				"the fixture must refuse the eager module-load engine initialization")
			helpers.assert_eq(gestures.start(), true,
				"runtime startup must retry an engine that never committed at module load")
			helpers.assert_eq(scheduler.engine_init_calls, 2,
				"the retry must occur before gesture runtime ownership is published")
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("rejects a primer start refusal, rolls back, and commits a clean retry", function()
		with_fixture({ primer_start_results = { false, true } }, function(gestures, scheduler)
			helpers.assert_eq(gestures.start(), false,
				"a present primer whose native start refuses must fail the gesture transaction")
			helpers.assert_eq(#scheduler.handles, 0,
				"primer failure must abort before discovery can be armed")
			helpers.assert_eq(scheduler.primer_handles[1].stop_calls, 1,
				"rollback must release the exact refused primer candidate")
			helpers.assert_eq(_G.ERGOPTI_GESTURE_PRIMER, nil,
				"a refused primer must never remain published")

			helpers.assert_eq(gestures.start(), true,
				"a later start must reacquire and commit the complete gesture runtime")
			helpers.assert_eq(#scheduler.primer_handles, 2)
			helpers.assert_eq(scheduler.primer_handles[2].running, true)
			helpers.assert_true(scheduler.engine_init_calls >= 2,
				"retry must restore the engine that startup rollback stopped")
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)

	helpers.it("rolls back primer and discovery when wake-watcher start raises, then retries", function()
		with_fixture({ wake_start_results = { "throw", true } }, function(gestures, scheduler)
			helpers.assert_eq(gestures.start(), false,
				"a wake watcher exception must not publish gesture startup success")
			helpers.assert_eq(#scheduler.handles, 1,
				"the failed attempt must have reached discovery before wake acquisition")
			helpers.assert_eq(scheduler.handles[1].active, false,
				"wake failure rollback must cancel the exact discovery timer")
			helpers.assert_eq(scheduler.primer_handles[1].running, false,
				"wake failure rollback must stop the already-committed primer")
			helpers.assert_eq(scheduler.wake_handles[1].stop_calls, 1,
				"rollback must release the exact wake-watcher candidate that raised")
			helpers.assert_eq(_G.ERGOPTI_SLEEP_WATCHER, nil,
				"a failed wake watcher must never remain published")

			helpers.assert_eq(gestures.start(), true,
				"a later attempt must replace every rolled-back native owner")
			helpers.assert_eq(#scheduler.handles, 2)
			helpers.assert_eq(scheduler.handles[2].active, true)
			helpers.assert_eq(scheduler.wake_handles[2].running, true)
			helpers.assert_true(scheduler.engine_stop_calls >= 1,
				"failed startup must run engine teardown as part of rollback")
			helpers.assert_true(scheduler.engine_init_calls >= 2,
				"the successful retry must restore the stopped gesture engine")
			helpers.assert_eq(gestures.stop(), true)
		end)
	end)
end)
