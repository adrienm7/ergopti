--- tests/unit/lib/test_ui_restore_timer_transaction.lua

--- ==============================================================================
--- MODULE: UI Restore Poller Transaction Regression Tests
--- DESCRIPTION:
--- Exercises the real deferred-reload gate against adversarial TimerScheduler
--- outcomes. A failed recurring-timer acquisition previously left the reload
--- callback parked forever, while a stop refusal discarded the only capability
--- that could release a live poller.
---
--- FEATURES & RATIONALE:
--- 1. Acquisition Failure: Nil, throw, and partial activation all fall back to
---    the pending reload instead of silently stranding it.
--- 2. Exact Cleanup: A partially acquired timer remains owned until a later stop
---    retries that same handle successfully.
--- 3. Stale Delivery: A callback queued before cancellation is generation-fenced
---    and cannot fire the reload twice.
--- ==============================================================================

local helpers = require("tests.helpers")





-- ===========================================
-- ===========================================
-- ======= 1/ Isolated Runtime Fixture =======
-- ===========================================
-- ===========================================

local MODULE_NAMES = {
	"adapters.storage",
	"adapters.timer_scheduler",
	"infra.logger",
	"infra.timings",
	"infra.ui_restore",
	"ui.hotstring_editor",
}

--- Runs one scenario with a visible protected UI and adversarial scheduler.
--- @param options table|nil Scheduler behavior controls.
--- @param scenario function Scenario receiving UI restore, scheduler, and UI state.
local function with_fixture(options, scenario)
	options = options or {}
	local saved = {}
	for _, name in ipairs(MODULE_NAMES) do
		saved[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local saved_hs = _G.hs

	local settings = options.settings or {}
	local ui_state = { open = options.initial_open ~= false, reopen_calls = 0, errors = {} }
	_G.hs = {
		configdir = "/tmp/ergopti-test",
		settings = {
			get = function(key) return settings[key] end,
			set = function(key, value) settings[key] = value end,
			clear = function(key) settings[key] = nil; return true end,
		},
	}
	local function noop() end
	package.loaded["infra.logger"] = setmetatable({}, {
		__index = function(_, method)
			if method == "error" then
				return function(_log, format, ...)
					ui_state.errors[#ui_state.errors + 1] = string.format(format, ...)
				end
			end
			return noop
		end,
	})
	package.loaded["infra.timings"] = { sec = function() return 1 end }

	package.loaded["ui.hotstring_editor"] = {
		is_open = function() return ui_state.open end,
		open = function()
			ui_state.reopen_calls = ui_state.reopen_calls + 1
			ui_state.open = options.reopen_opens ~= false
		end,
	}

	local scheduler = {
		handles = {},
		after_handles = {},
		cancel_calls = {},
	}
	function scheduler.every(_, callback)
		local mode = options.every_mode or "commit"
		if mode == "throw" then error("poller constructor exploded") end
		if mode == "nil" then return nil, false end
		local handle = { active = true, callback = callback, timer = {} }
		scheduler.handles[#scheduler.handles + 1] = handle
		return handle, mode == "commit"
	end
	function scheduler.after(_, callback)
		local mode = options.after_mode or "commit"
		if mode == "throw" then error("one-shot constructor exploded") end
		if mode == "nil" then return nil, false end
		local handle = { active = true, callback = callback, timer = {} }
		scheduler.after_handles[#scheduler.after_handles + 1] = handle
		return handle, mode == "commit"
	end
	function scheduler.cancel(handle)
		scheduler.cancel_calls[#scheduler.cancel_calls + 1] = handle
		local result = options.cancel_results
			and options.cancel_results[#scheduler.cancel_calls]
		if result == "throw" then error("poller cancel exploded") end
		if result == false then return false end
		handle.active = false
		handle.timer = nil
		return true
	end
	package.loaded["adapters.timer_scheduler"] = scheduler

	local ui_restore = require("infra.ui_restore")
	local ok, err = xpcall(function()
		scenario(ui_restore, scheduler, ui_state)
	end, debug.traceback)
	ui_restore.stop()
	_G.hs = saved_hs
	for _, name in ipairs(MODULE_NAMES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end





-- =========================================
-- =========================================
-- ======= 2/ Poller Transactions ==========
-- =========================================
-- =========================================

helpers.describe("ui_restore deferred reload owns one exact poller transaction", function()
	helpers.it("fires once after the UI closes and fences a queued stale callback", function()
		with_fixture({}, function(ui_restore, scheduler, ui_state)
			local reloads = 0
			helpers.assert_eq(ui_restore.defer_reload(function()
				reloads = reloads + 1
			end), true)
			helpers.assert_eq(#scheduler.handles, 1)
			local poller = scheduler.handles[1]

			poller.callback()
			helpers.assert_eq(reloads, 0, "an open protected UI must keep the reload pending")
			ui_state.open = false
			poller.callback()
			helpers.assert_eq(reloads, 1)
			helpers.assert_eq(scheduler.cancel_calls[1], poller,
				"the callback must cancel the exact poller capability")

			poller.callback()
			helpers.assert_eq(reloads, 1,
				"a callback queued before stop must be generation-fenced")
		end)
	end)

	helpers.it("does not strand a reload when poller construction throws or returns nil", function()
		for _, mode in ipairs({ "throw", "nil" }) do
			with_fixture({ every_mode = mode }, function(ui_restore, scheduler)
				local reloads = 0
				helpers.assert_eq(ui_restore.defer_reload(function()
					reloads = reloads + 1
				end), false)
				helpers.assert_eq(reloads, 1,
					"a missing poller must fail open to the recovery reload")
				helpers.assert_eq(#scheduler.handles, 0)
				helpers.assert_eq(ui_restore.stop(), true)
			end)
		end
	end)

	helpers.it("retains partial acquisition through stop refusal and retries exact cleanup", function()
		with_fixture({ every_mode = "partial", cancel_results = { false, true } },
			function(ui_restore, scheduler)
				local reloads = 0
				helpers.assert_eq(ui_restore.defer_reload(function()
					reloads = reloads + 1
				end), false)
				local partial = scheduler.handles[1]
				helpers.assert_eq(reloads, 1,
					"partial activation must not leave the reload callback parked")
				helpers.assert_eq(partial.active, true,
					"native cleanup refusal must retain the exact live candidate")
				partial.callback()
				helpers.assert_eq(reloads, 1,
					"the uncommitted candidate callback must remain logically inert")

				helpers.assert_eq(ui_restore.stop(), true)
				helpers.assert_eq(scheduler.cancel_calls[2], partial,
					"the later lifecycle pass must retry the same candidate")
				helpers.assert_eq(partial.active, false)
			end)
	end)

	helpers.it("gives a re-entrant non-terminal reload one later opportunity", function()
		with_fixture({}, function(ui_restore, scheduler, ui_state)
			ui_state.open = false
			local outer_calls = 0
			local inner_calls = 0
			helpers.assert_eq(ui_restore.defer_reload(function()
				outer_calls = outer_calls + 1
				helpers.assert_eq(ui_restore.defer_reload(function()
					inner_calls = inner_calls + 1
				end), true)
			end), true)
			helpers.assert_eq(outer_calls, 1)
			helpers.assert_eq(inner_calls, 0,
				"re-entrant reload must not double-fire on the outer callback stack")
			helpers.assert_eq(#scheduler.after_handles, 1,
				"the queued request must own a real next async opportunity")

			local dispatch = scheduler.after_handles[1]
			dispatch.active = false
			dispatch.timer = nil
			dispatch.callback()
			helpers.assert_eq(inner_calls, 1,
				"a refused/non-terminal outer reload must not strand the queued callback")
			dispatch.callback()
			helpers.assert_eq(inner_calls, 1,
				"a stale one-shot delivery must remain idempotent")
		end)
	end)

	helpers.it("retires an older polled batch before a newer fast-path reload", function()
		with_fixture({}, function(ui_restore, scheduler, ui_state)
			local older_calls = 0
			local newer_calls = 0
			helpers.assert_true(ui_restore.defer_reload(function()
				older_calls = older_calls + 1
			end))
			local poller = scheduler.handles[1]

			ui_state.open = false
			helpers.assert_true(ui_restore.defer_reload(function()
				newer_calls = newer_calls + 1
			end))
			helpers.assert_eq(newer_calls, 1,
				"the newest reload must retain the immediate fast path")
			helpers.assert_eq(older_calls, 0,
				"the superseded deferred batch must not run behind the newer reload")
			helpers.assert_eq(scheduler.cancel_calls[1], poller,
				"the fast path must retire the exact old poller")
			helpers.assert_eq(#scheduler.after_handles, 0,
				"retiring the old callback must not arm a stale dispatch")

			poller.callback()
			helpers.assert_eq(older_calls, 0,
				"a queued callback from the retired poller must remain inert")
		end)
	end)

	helpers.it("retires an older one-shot batch before a newer fast-path reload", function()
		with_fixture({}, function(ui_restore, scheduler, ui_state)
			ui_state.open = false
			local older_calls = 0
			local newer_calls = 0
			helpers.assert_true(ui_restore.defer_reload(function()
				helpers.assert_true(ui_restore.defer_reload(function()
					older_calls = older_calls + 1
				end))
			end))
			local dispatch = scheduler.after_handles[1]

			helpers.assert_true(ui_restore.defer_reload(function()
				newer_calls = newer_calls + 1
			end))
			helpers.assert_eq(newer_calls, 1)
			helpers.assert_eq(older_calls, 0)
			helpers.assert_eq(scheduler.cancel_calls[1], dispatch,
				"the fast path must retire the exact queued one-shot")

			dispatch.callback()
			helpers.assert_eq(older_calls, 0,
				"a queued callback from the retired one-shot must remain inert")
		end)
	end)

	helpers.it("fences a superseded batch while exact timer cleanup is still owed", function()
		with_fixture({ cancel_results = { false, true } },
			function(ui_restore, scheduler, ui_state)
				local older_calls = 0
				local newer_calls = 0
				helpers.assert_true(ui_restore.defer_reload(function()
					older_calls = older_calls + 1
				end))
				local poller = scheduler.handles[1]

				ui_state.open = false
				helpers.assert_eq(ui_restore.defer_reload(function()
					newer_calls = newer_calls + 1
				end), false, "unsettled native cleanup must remain visible")
				helpers.assert_eq(newer_calls, 1,
					"timer cleanup debt must not suppress the newest reload")
				helpers.assert_eq(poller.active, true,
					"the exact refused timer capability must remain retained")

				poller.callback()
				helpers.assert_eq(older_calls, 0,
					"generation fencing must make the retained stale callback inert")
				helpers.assert_true(ui_restore.stop())
				helpers.assert_eq(scheduler.cancel_calls[2], poller,
					"lifecycle cleanup must retry the exact retained timer")
			end)
	end)
end)





-- =========================================
-- =========================================
-- ======= 3/ Delayed UI Restore Ownership =
-- =========================================
-- =========================================

helpers.describe("ui_restore delayed reopen is lifecycle-owned", function()
	helpers.it("reports a restore callback that returns without opening its UI", function()
		with_fixture({
			initial_open = false,
			reopen_opens = false,
			settings = { ["ergopti.ui_restore_state"] = { "hotstring_editor" } },
		}, function(ui_restore, scheduler, ui_state)
			helpers.assert_eq(ui_restore.restore(), true)
			local restore_timer = scheduler.after_handles[1]
			restore_timer.callback()
			helpers.assert_eq(ui_state.reopen_calls, 1)
			helpers.assert_eq(ui_state.open, false)
			helpers.assert_eq(#ui_state.errors, 1,
				"a normal return without an opened UI must remain visible")
			helpers.assert_contains(ui_state.errors[1], "Failed to restore UI 'hotstring_editor'")
		end)
	end)

	helpers.it("reopens immediately when the one-shot constructor is unavailable", function()
		with_fixture({
			after_mode = "nil",
			settings = { ["ergopti.ui_restore_state"] = { "hotstring_editor" } },
		}, function(ui_restore, scheduler, ui_state)
			helpers.assert_eq(ui_restore.restore(), false)
			helpers.assert_eq(ui_state.reopen_calls, 1,
				"timer failure must not silently drop the promised UI")
			helpers.assert_eq(#scheduler.after_handles, 0)
		end)
	end)

	helpers.it("stop fences a queued restore and retries its exact timer", function()
		with_fixture({
			cancel_results = { false, true },
			settings = { ["ergopti.ui_restore_state"] = { "hotstring_editor" } },
		}, function(ui_restore, scheduler, ui_state)
			helpers.assert_eq(ui_restore.restore(), true)
			local restore_timer = scheduler.after_handles[1]
			helpers.assert_eq(ui_restore.stop(), false,
				"native stop refusal must remain visible and retryable")
			restore_timer.callback()
			helpers.assert_eq(ui_state.reopen_calls, 0,
				"a restore queued before shutdown must not resurrect UI")

			helpers.assert_eq(ui_restore.stop(), true)
			helpers.assert_eq(scheduler.cancel_calls[2], restore_timer,
				"the second stop must retry the original one-shot capability")
		end)
	end)
end)
