--- tests/unit/platform/remap/test_onboarding_continuation_timer_transaction.lua

--- ==============================================================================
--- MODULE: Karabiner Onboarding Continuation Transaction Regression Tests
--- DESCRIPTION:
--- Exercises successful polling and installer completions through the real
--- onboarding state machine, then tears it down before queued continuations run.
--- It proves a stopped Karabiner bridge cannot reopen the wizard later.
---
--- FEATURES & RATIONALE:
--- 1. Poll Terminal Ownership: A successor is armed only after exact poll stop.
--- 2. Stop Fence: Queued one-shot callbacks cannot re-enter the wizard.
--- 3. Installer Fence: A task completion after stop cannot create a timer.
--- 4. Cleanup Debt: Refused poll cancellation blocks every sibling timer.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Isolated Wizard Fixture ========
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

--- Runs one onboarding scenario with deterministic timer and UI boundaries.
--- @param options table Scenario controls.
--- @param scenario function Scenario receiving onboarding, scheduler, and calls.
local function with_fixture(options, scenario)
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

	local calls = {
		after = 0,
		cancel = 0,
		every = 0,
		health = 0,
		notices = {},
	}
	local cancel_results = options.cancel_results or {}
	local scheduler = { after_handles = {}, every_handles = {} }

	local function selected_mode(sequence, fallback, index)
		if type(sequence) == "table" and sequence[index] ~= nil then return sequence[index] end
		return fallback or "commit"
	end

	function scheduler.after(_, callback)
		calls.after = calls.after + 1
		local mode = selected_mode(options.after_modes, options.after_mode, calls.after)
		if mode == "throw" then error("onboarding-after-throw") end
		local active = mode ~= "nil"
		local handle = {
			active = active,
			callback = callback,
			committed = mode == "commit",
			kind = "after",
			timer = active and {} or nil,
		}
		scheduler.after_handles[#scheduler.after_handles + 1] = handle
		return handle, mode == "commit"
	end

	function scheduler.every(_, callback)
		calls.every = calls.every + 1
		local mode = selected_mode(options.every_modes, options.every_mode, calls.every)
		if mode == "throw" then error("onboarding-every-throw") end
		local active = mode ~= "nil"
		local handle = {
			active = active,
			callback = callback,
			committed = mode == "commit",
			kind = "every",
			timer = active and {} or nil,
		}
		scheduler.every_handles[#scheduler.every_handles + 1] = handle
		return handle, mode == "commit"
	end

	function scheduler.cancel(handle)
		if type(handle) ~= "table" or handle.timer == nil then return true end
		calls.cancel = calls.cancel + 1
		handle.committed = false
		local result = cancel_results[calls.cancel]
		if result == "throw" then error("onboarding-cancel-throw") end
		if result == false then return false end
		if result == "nil" then return nil end
		handle.active = false
		handle.timer = nil
		return true
	end

	local function noop() end
	package.loaded["adapters.task_lifecycle"] = { start = function() return false end }
	package.loaded["adapters.timer_scheduler"] = scheduler
	package.loaded["infra.dialog_util"] = {
		block_alert = function() return options.choice end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.logger"] = setmetatable({}, { __index = function() return noop end })
	package.loaded["infra.notifications"] = {
		notify = function(message, _, kind)
			calls.notices[#calls.notices + 1] = { message = message, kind = kind }
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
		calls.health = calls.health + 1
		if type(options.health_reports) == "table" then
			return options.health_reports[calls.health] or options.health_reports[#options.health_reports]
		end
		return options.report
	end
	onboarding.open_system_extensions_pane = noop
	onboarding.open_accessibility_pane = noop
	onboarding.is_sysext_activated = function() return options.poll_ready == true end
	onboarding.is_grabber_running = function() return options.poll_ready == true end

	local ok, err = xpcall(function()
		scenario(onboarding, scheduler, calls)
	end, debug.traceback)
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved_modules[name] end
	if not ok then error(err, 0) end
end





-- ============================================
-- ============================================
-- ======= 2/ Continuation Ownership ==========
-- ============================================
-- ============================================

helpers.describe("Karabiner onboarding owns every delayed continuation", function()
	helpers.it("onboarding timer stop fences a queued post-poll continuation", function()
		with_fixture({
			choice = "karabiner.onboarding.btn_open_settings",
			poll_ready = true,
			report = {
				all_ok = false,
				ke_installed = true,
				grabber_present = true,
				sysext_activated = false,
				grabber_running = true,
			},
		}, function(onboarding, scheduler, calls)
			onboarding.run_first_run_wizard()
			helpers.assert_eq(calls.every, 1)
			scheduler.every_handles[1].callback()
			helpers.assert_eq(calls.cancel, 1,
				"the recurring poll must settle before its successor is acquired")
			helpers.assert_eq(calls.after, 1)
			local queued = scheduler.after_handles[1].callback

			helpers.assert_eq(onboarding.stop(), true)
			helpers.assert_eq(calls.cancel, 2)
			queued()
			helpers.assert_eq(calls.health, 1,
				"a callback queued before stop must not reopen the wizard")
		end)
	end)

	helpers.it("onboarding timer cleanup retries before the post-success sibling", function()
		with_fixture({
			choice = "karabiner.onboarding.btn_open_settings",
			poll_ready = true,
			cancel_results = { false, true },
			report = {
				all_ok = false,
				ke_installed = true,
				grabber_present = true,
				sysext_activated = false,
				grabber_running = true,
			},
		}, function(onboarding, scheduler, calls)
			onboarding.run_first_run_wizard()
			scheduler.every_handles[1].callback()
			helpers.assert_eq(calls.after, 1,
				"bounded exact cleanup must acquire the sibling without another user action")
			helpers.assert_eq(#calls.notices, 2,
				"successful cleanup may publish the poll result exactly once")
			helpers.assert_eq(onboarding.stop(), true)
			helpers.assert_eq(calls.cancel, 3)
		end)
	end)

	helpers.it("onboarding timer fence rejects an installer completion after stop", function()
		with_fixture({
			choice = "karabiner.onboarding.btn_install_now",
			report = {
				all_ok = false,
				ke_installed = false,
				grabber_present = false,
				sysext_activated = false,
				grabber_running = false,
			},
		}, function(onboarding, _, calls)
			local install_callback
			onboarding.install_karabiner_elements = function(callback)
				install_callback = callback
			end
			onboarding.run_first_run_wizard()
			helpers.assert_not_nil(install_callback)
			helpers.assert_eq(onboarding.stop(), true)
			install_callback(true, nil)
			helpers.assert_eq(calls.after, 0)
			helpers.assert_eq(calls.health, 1,
				"a stale installer task must not reopen onboarding after teardown")
		end)
	end)

	helpers.it("onboarding timer retains a partially acquired post-success continuation", function()
		with_fixture({
			choice = "karabiner.onboarding.btn_open_settings",
			poll_ready = true,
			after_mode = "partial",
			cancel_results = { true, false, false, false, false, false, true },
			health_reports = {
				{
					all_ok = false,
					ke_installed = true,
					grabber_present = true,
					sysext_activated = false,
					grabber_running = true,
				},
				{
					all_ok = true,
					ke_installed = true,
					grabber_present = true,
					sysext_activated = true,
					grabber_running = true,
				},
			},
		}, function(onboarding, scheduler, calls)
			onboarding.run_first_run_wizard()
			scheduler.every_handles[1].callback()
			helpers.assert_eq(calls.after, 1)
			helpers.assert_eq(scheduler.after_handles[1].active, true)
			helpers.assert_eq(calls.cancel, 4,
				"failed post-success acquisition must exhaust bounded exact rollback")

			scheduler.after_handles[1].callback()
			helpers.assert_eq(calls.cancel, 7,
				"a stale partial callback must settle the same exact handle autonomously")
			helpers.assert_eq(calls.health, 2,
				"the uncommitted continuation callback must never reopen the wizard")
			helpers.assert_eq(onboarding.stop(), true)
			helpers.assert_eq(calls.cancel, 7)
		end)
	end)

	helpers.it("onboarding timer rejects thrown and nil recurring acquisitions", function()
		for _, mode in ipairs({ "throw", "nil" }) do
			with_fixture({
				choice = "karabiner.onboarding.btn_open_settings",
				every_mode = mode,
				report = {
					all_ok = false,
					ke_installed = true,
					grabber_present = true,
					sysext_activated = false,
					grabber_running = true,
				},
			}, function(onboarding, _, calls)
				onboarding.run_first_run_wizard()
				helpers.assert_eq(calls.every, 3,
					"recurring timer construction must exhaust its bounded retry series")
				helpers.assert_eq(calls.after, 0)
				helpers.assert_eq(#calls.notices, 2,
					"timer acquisition failure must surface one terminal warning")
				helpers.assert_eq(onboarding.stop(), true)
			end)
		end
	end)

	helpers.it("onboarding timer falls back after thrown and nil continuation acquisitions", function()
		for _, mode in ipairs({ "throw", "nil" }) do
			with_fixture({
				choice = "karabiner.onboarding.btn_open_settings",
				poll_ready = true,
				after_mode = mode,
				health_reports = {
					{
						all_ok = false,
						ke_installed = true,
						grabber_present = true,
						sysext_activated = false,
						grabber_running = true,
					},
					{
						all_ok = true,
						ke_installed = true,
						grabber_present = true,
						sysext_activated = true,
						grabber_running = true,
					},
				},
			}, function(onboarding, scheduler, calls)
				onboarding.run_first_run_wizard()
				scheduler.every_handles[1].callback()
				helpers.assert_eq(calls.after, 3,
					"continuation construction must exhaust its bounded retry series")
				helpers.assert_eq(calls.health, 2,
					"a missing timer must not silently drop the next wizard step")
				helpers.assert_eq(onboarding.stop(), true)
			end)
		end
	end)

	helpers.it("onboarding timer constructor refusal acquires a bounded successor", function()
		with_fixture({
			choice = "karabiner.onboarding.btn_open_settings",
			every_modes = { "partial", "commit" },
			report = {
				all_ok = false,
				ke_installed = true,
				grabber_present = true,
				sysext_activated = false,
				grabber_running = true,
			},
		}, function(onboarding, scheduler, calls)
			onboarding.run_first_run_wizard()
			helpers.assert_eq(calls.every, 2)
			helpers.assert_nil(scheduler.every_handles[1].timer,
				"the refused wrapper must settle before successor acquisition")
			helpers.assert_not_nil(scheduler.every_handles[2].timer)
			helpers.assert_eq(calls.cancel, 1)
			helpers.assert_eq(#calls.notices, 1,
				"successful fallback acquisition must not publish a false timeout")
			helpers.assert_eq(onboarding.stop(), true)
		end)
	end)

	helpers.it("onboarding continuation constructor refusal acquires a bounded successor", function()
		with_fixture({
			choice = "karabiner.onboarding.btn_open_settings",
			poll_ready = true,
			after_modes = { "partial", "commit" },
			health_reports = {
				{
					all_ok = false,
					ke_installed = true,
					grabber_present = true,
					sysext_activated = false,
					grabber_running = true,
				},
				{
					all_ok = true,
					ke_installed = true,
					grabber_present = true,
					sysext_activated = true,
					grabber_running = true,
				},
			},
		}, function(onboarding, scheduler, calls)
			onboarding.run_first_run_wizard()
			scheduler.every_handles[1].callback()
			helpers.assert_eq(calls.after, 2)
			helpers.assert_nil(scheduler.after_handles[1].timer)
			helpers.assert_not_nil(scheduler.after_handles[2].timer)
			helpers.assert_eq(calls.health, 1,
				"successful timer fallback must not run the continuation early")
			scheduler.after_handles[2].callback()
			helpers.assert_eq(calls.health, 2)
			helpers.assert_eq(onboarding.stop(), true)
		end)
	end)

	for _, refusal in ipairs({ false, "throw" }) do
		helpers.it("onboarding stop bounds exact timer cancel " .. tostring(refusal), function()
			with_fixture({
				choice = "karabiner.onboarding.btn_open_settings",
				cancel_results = { refusal, refusal, refusal, true },
				report = {
					all_ok = false,
					ke_installed = true,
					grabber_present = true,
					sysext_activated = false,
					grabber_running = true,
				},
			}, function(onboarding, scheduler, calls)
				onboarding.run_first_run_wizard()
				helpers.assert_true(onboarding.stop() == false)
				helpers.assert_eq(calls.cancel, 3)
				helpers.assert_not_nil(scheduler.every_handles[1].timer,
					"terminal refusal must retain the exact callback-inert wrapper")
				scheduler.every_handles[1].callback()
				helpers.assert_eq(calls.cancel, 4,
					"a later native delivery must settle debt without another user gesture")
				helpers.assert_nil(scheduler.every_handles[1].timer)
				helpers.assert_eq(#calls.notices, 1,
					"cleanup-only delivery must not publish a false wizard terminal")
			end)
		end)
	end
end)
