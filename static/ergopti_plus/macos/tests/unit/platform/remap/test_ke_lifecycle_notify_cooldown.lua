--- tests/unit/platform/remap/test_ke_lifecycle_notify_cooldown.lua

--- ==============================================================================
--- MODULE: Karabiner Ready Notification Cooldown Regression Tests
--- DESCRIPTION:
--- Proves behaviorally that boot and cooldown deferrals retain the exact READY
--- notification, retry it once eligible, and invalidate superseded timers.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh lifecycle over deterministic timer and lease controls.
--- @return table lifecycle
--- @return table ctx
local function load_lifecycle()
	local ctx = {
		phase = "active",
		token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		boot_ready = true,
		now = 100,
		timers = {},
		notifications = 0,
	}

	package.loaded["platform.remap.ke_lifecycle"] = nil
	package.loaded["platform.remap.lease_controller"] = {
		status = function()
			return ctx.phase, { phase = ctx.phase, token = ctx.token }
		end,
	}
	local logger = {}
	for _, level in ipairs({ "debug", "info", "warn", "error", "start", "success" }) do
		logger[level] = function() end
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.notifications"] = {
		notify = function()
			ctx.notifications = ctx.notifications + 1
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.text_utils"] = { shell_quote = function(value) return value end }
	package.loaded["platform.remap.ke_paths"] = {
		CORE_SERVICE = "/stock/Karabiner-Core-Service",
		GRABBER = "/stock/karabiner_grabber",
	}

	local lifecycle = helpers.load_with_stubs("platform.remap.ke_lifecycle", {
		settings = { get = function() return ctx.boot_ready end },
		timer = {
			secondsSinceEpoch = function() return ctx.now end,
			doAfter = function(delay, callback)
				local timer = {
					delay = delay,
					callback = callback,
					stop_calls = 0,
				}
				function timer:stop()
					self.stop_calls = self.stop_calls + 1
					return true
				end
				ctx.timers[#ctx.timers + 1] = timer
				return timer
			end,
		},
		execute = function() return "", true end,
		application = { launchOrFocus = function() return true end },
	})
	return lifecycle, ctx
end

helpers.describe("ke_lifecycle READY notification deferrals", function()
	helpers.it("flushes a notification retained while boot was not ready", function()
		local lifecycle, ctx = load_lifecycle()
		ctx.boot_ready = false

		lifecycle.notify_ready()
		helpers.assert_eq(#ctx.timers, 0,
			"boot deferral must not schedule a READY banner before boot completion")

		ctx.boot_ready = true
		lifecycle.flush_pending_ready_notification()
		helpers.assert_eq(#ctx.timers, 1,
			"boot completion must recover the exact deferred READY notification")
		ctx.timers[1].callback()
		helpers.assert_eq(ctx.notifications, 1)
	end)

	helpers.it("delivers a cooldown-suppressed notification after its retry", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		ctx.timers[1].callback()
		helpers.assert_eq(ctx.notifications, 1)

		ctx.now = 101
		lifecycle.notify_ready()
		ctx.timers[2].callback()
		helpers.assert_eq(ctx.notifications, 1,
			"the second READY notification must remain suppressed during cooldown")
		helpers.assert_eq(#ctx.timers, 3,
			"cooldown suppression must retain one real retry trigger")

		ctx.now = 111
		ctx.timers[3].callback()
		helpers.assert_eq(#ctx.timers, 4,
			"the retry must restore the ordinary delayed exact-token check")
		ctx.timers[4].callback()
		helpers.assert_eq(ctx.notifications, 2,
			"a cooldown-suppressed READY notification must not be lost")
	end)

	helpers.it("stops and fences a superseded cooldown retry", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		ctx.timers[1].callback()
		ctx.now = 101
		lifecycle.notify_ready()
		ctx.timers[2].callback()
		local stale_retry = ctx.timers[3]

		lifecycle.notify_ready()
		helpers.assert_eq(stale_retry.stop_calls, 1,
			"a newer READY request must stop the exact prior retry timer")
		local timer_count = #ctx.timers
		stale_retry.callback()
		helpers.assert_eq(#ctx.timers, timer_count,
			"a superseded retry callback must not schedule replacement work")
		helpers.assert_eq(ctx.notifications, 1,
			"a superseded retry callback must not publish a stale banner")
	end)
end)
