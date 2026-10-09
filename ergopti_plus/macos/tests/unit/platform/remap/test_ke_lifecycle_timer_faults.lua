--- tests/unit/platform/remap/test_ke_lifecycle_timer_faults.lua

--- ==============================================================================
--- MODULE: Karabiner Ready Notification Timer Fault Tests
--- DESCRIPTION:
--- Exercises timer allocation, callback and cancellation failures around the
--- token-scoped ready banner without touching any stock Karabiner process.
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
		fail_timer_creations = {},
		fire_timer_synchronously = {},
		timer_creation_count = 0,
		notifications = 0,
		fail_notification_once = false,
		stock_execute_calls = 0,
		stock_launch_calls = 0,
		logs = {},
	}

	package.loaded["platform.remap.ke_lifecycle"] = nil
	package.loaded["platform.remap.lease_controller"] = {
		status = function()
			return ctx.phase, { phase = ctx.phase, token = ctx.token }
		end,
	}
	local logger = {}
	for _, level in ipairs({ "debug", "info", "warn", "error", "start", "success" }) do
		logger[level] = function(_, message)
			ctx.logs[#ctx.logs + 1] = level .. ":" .. tostring(message)
		end
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.notifications"] = {
		notify = function()
			if ctx.fail_notification_once then
				ctx.fail_notification_once = false
				error("notification callback fault")
			end
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
				ctx.timer_creation_count = ctx.timer_creation_count + 1
				if ctx.fail_timer_creations[ctx.timer_creation_count] then
					error("timer allocation fault")
				end
				local timer = {
					delay = delay,
					callback = callback,
					stop_calls = 0,
					fail_stop = false,
				}
				function timer:stop()
					self.stop_calls = self.stop_calls + 1
					if self.fail_stop then error("timer cancellation fault") end
				end
				ctx.timers[#ctx.timers + 1] = timer
				if ctx.fire_timer_synchronously[ctx.timer_creation_count] then callback() end
				return timer
			end,
		},
		execute = function()
			ctx.stock_execute_calls = ctx.stock_execute_calls + 1
			return "", true
		end,
		application = {
			launchOrFocus = function()
				ctx.stock_launch_calls = ctx.stock_launch_calls + 1
				return true
			end,
		},
	})
	return lifecycle, ctx
end

helpers.describe("ke_lifecycle ready timers fail closed without losing the banner", function()
	helpers.it("falls back synchronously when the initial delay timer cannot be created", function()
		local lifecycle, ctx = load_lifecycle()
		ctx.fail_timer_creations[1] = true

		-- A throw fails the test runner directly; the observable notification below
		-- proves the fallback completed instead of accepting a pcall-only false green.
		lifecycle.notify_ready()
		helpers.assert_eq(ctx.notifications, 1,
			"an unavailable delay timer must degrade to an immediate exact-token banner")
		helpers.assert_eq(ctx.stock_execute_calls, 0)
		helpers.assert_eq(ctx.stock_launch_calls, 0)
	end)

	helpers.it("delivers rather than losing a cooldown banner when its retry timer cannot be created", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		ctx.timers[1].callback()
		helpers.assert_eq(ctx.notifications, 1)

		ctx.now = 101
		lifecycle.notify_ready()
		ctx.fail_timer_creations[3] = true
		ctx.timers[2].callback()

		helpers.assert_eq(ctx.notifications, 2,
			"retry allocation failure must bypass cooldown instead of dropping READY forever")
		helpers.assert_eq(ctx.stock_execute_calls, 0)
		helpers.assert_eq(ctx.stock_launch_calls, 0)
	end)

	helpers.it("retries a notification callback fault and eventually delivers once", function()
		local lifecycle, ctx = load_lifecycle()
		ctx.fail_notification_once = true
		lifecycle.notify_ready()

		local ok, err = pcall(ctx.timers[1].callback)
		helpers.assert_true(ok, "async callback failures must remain contained: " .. tostring(err))
		helpers.assert_eq(ctx.notifications, 0)
		helpers.assert_eq(#ctx.timers, 2,
			"a failed notification callback must retain one bounded retry trigger")

		ctx.timers[2].callback()
		helpers.assert_eq(#ctx.timers, 3,
			"the retry must restore the ordinary delayed exact-token check")
		ctx.timers[3].callback()
		helpers.assert_eq(ctx.notifications, 1)
	end)

	helpers.it("invalidates a timer whose cancellation failed before same-token resume", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		local stale = ctx.timers[1]
		stale.fail_stop = true

		ctx.phase = "paused"
		helpers.assert_eq(lifecycle.stop(), false,
			"the first failed exact timer stop must keep local teardown retryable")
		ctx.phase = "active"
		local ok, err = pcall(stale.callback)

		helpers.assert_true(ok, "a stale callback must be harmless: " .. tostring(err))
		helpers.assert_eq(ctx.notifications, 0,
			"failed timer cancellation must not resurrect a pre-teardown READY banner")
		helpers.assert_eq(ctx.stock_execute_calls, 0)
		helpers.assert_eq(ctx.stock_launch_calls, 0)

		stale.fail_stop = false
		helpers.assert_eq(lifecycle.stop(), true,
			"the retained exact timer handle must be stopped by the next teardown attempt")
		helpers.assert_eq(stale.stop_calls, 2)
	end)

	helpers.it("stops a retry-only timer when no delayed timer occupies the first slot", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		ctx.timers[1].callback()
		ctx.now = 101
		lifecycle.notify_ready()
		ctx.timers[2].callback()
		local retry_timer = ctx.timers[3]

		helpers.assert_eq(lifecycle.stop(), true)
		helpers.assert_eq(retry_timer.stop_calls, 1,
			"a dense cleanup list must not skip retry when the primary timer slot is nil")
	end)

	helpers.it("publishes a synchronously fired timer before authorizing its callback", function()
		local lifecycle, ctx = load_lifecycle()
		ctx.fire_timer_synchronously[1] = true

		lifecycle.notify_ready()
		helpers.assert_eq(ctx.notifications, 1)
		helpers.assert_eq(#ctx.timers, 1)

		ctx.timers[1].callback()
		helpers.assert_eq(ctx.notifications, 1)
		helpers.assert_eq(#ctx.timers, 1,
			"an already-consumed synchronous timer must not schedule work after supersession")
	end)
end)
