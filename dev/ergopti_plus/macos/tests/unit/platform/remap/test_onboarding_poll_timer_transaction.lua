--- tests/unit/platform/remap/test_onboarding_poll_timer_transaction.lua

--- ==============================================================================
--- MODULE: Karabiner Onboarding Poll-Timer Transaction Regression Tests
--- DESCRIPTION:
--- Drives the public first-run wizard into its System Extension polling branch
--- with an adversarial recurring timer that became active but failed to commit.
--- It proves the callback owns a stable transaction object rather than a local
--- handle that remains nil when timer construction raises after native start.
---
--- FEATURES & RATIONALE:
--- 1. Partial Acquisition: Returns the exact active timer with committed=false.
--- 2. Deferred Retry: Refuses the first cancel, then fires the real callback so
---    cleanup must retry without throwing inside the asynchronous boundary.
--- 3. Single Terminal Result: Confirms acquisition failure surfaces timeout once
---    and the stale native tick cannot emit a second wizard result.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Isolated Runtime Fixture =======
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"hs",
	"infra.dialog_util",
	"infra.i18n",
	"infra.logger",
	"infra.notifications",
	"infra.text_utils",
	"platform.remap.ke_paths",
	"platform.remap.onboarding",
	"tests.stubs.hs",
}

--- Runs an onboarding scenario with deterministic dependencies and cleanup.
--- @param scenario function Scenario receiving onboarding, scheduler, and notices.
local function with_fixture(scenario)
	local saved_modules = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved_modules[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local saved_hs = _G.hs

	local hs_stub = require("tests.stubs.hs")
	hs_stub.__reset()
	_G.hs = hs_stub
	package.loaded["hs"] = hs_stub

	local notices = {}
	local scheduler = { cancel_calls = 0 }
	function scheduler.every(_, callback)
		local handle = { active = true, callback = callback, cancel_refusals = 2 }
		scheduler.handle = handle
		return handle, false
	end
	function scheduler.cancel(handle)
		if type(handle) ~= "table" or handle.active ~= true then return true end
		scheduler.cancel_calls = scheduler.cancel_calls + 1
		if handle.cancel_refusals > 0 then
			handle.cancel_refusals = handle.cancel_refusals - 1
			return false
		end
		handle.active = false
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler

	local function noop() end
	package.loaded["adapters.task_lifecycle"] = { start = function() return false end }
	package.loaded["infra.dialog_util"] = {
		block_alert = function() return "karabiner.onboarding.btn_open_settings" end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.notifications"] = {
		notify = function(message, _, kind)
			notices[#notices + 1] = { message = message, kind = kind }
		end,
	}
	package.loaded["infra.text_utils"] = { shell_quote = function(value) return value end }
	package.loaded["platform.remap.ke_paths"] = {
		CLI = "/test/karabiner_cli",
		CORE_SERVICE = "/test/Karabiner-Core-Service",
		GRABBER = "/test/karabiner_grabber",
	}

	local onboarding = require("platform.remap.onboarding")
	onboarding.health_check = function()
		return {
			all_ok = false,
			ke_installed = true,
			grabber_present = true,
			sysext_activated = false,
			grabber_running = true,
		}
	end
	onboarding.open_system_extensions_pane = noop
	onboarding.is_sysext_activated = function() return false end

	local ok, err = xpcall(function() scenario(onboarding, scheduler, notices) end, debug.traceback)
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end





-- =======================================
-- =======================================
-- ======= 2/ Poll Timer Rollback ========
-- =======================================
-- =======================================

helpers.describe("Karabiner onboarding polling owns partial recurring timers", function()
	helpers.it("onboarding timer retries partial acquisition without a nil-handle callback crash", function()
		with_fixture(function(onboarding, scheduler, notices)
			helpers.assert_eq(onboarding.run_first_run_wizard(), nil)
			helpers.assert_not_nil(scheduler.handle,
				"the wizard must have reached the real recurring-poll acquisition")
			helpers.assert_eq(scheduler.cancel_calls, 1,
				"failed acquisition must immediately attempt exact rollback")
			helpers.assert_eq(scheduler.handle.active, true,
				"native stop refusal leaves a live callback that must retain cleanup context")
			helpers.assert_eq(#notices, 2,
				"the waiting notice and one timeout notice are the only terminal output")

			local ok_callback, cancel_calls_or_err = pcall(function()
				scheduler.handle.callback()
				return scheduler.cancel_calls
			end)
			helpers.assert_eq(ok_callback, true,
				"the callback must not dereference the nil constructor-assignment local: "
					.. tostring(cancel_calls_or_err))
			helpers.assert_eq(cancel_calls_or_err, 2,
				"the stale callback must retry cancellation of the exact retained handle")
			helpers.assert_eq(scheduler.handle.active, true,
				"a second native stop refusal must remain module-owned after the callback")
			helpers.assert_eq(#notices, 2,
				"a cleanup-only stale tick must not invoke the timeout callback twice")
			helpers.assert_eq(onboarding.stop(), true,
				"module teardown must retry the exact polling timer after callback fencing")
			helpers.assert_eq(scheduler.handle.active, false)
		end)
	end)
end)
