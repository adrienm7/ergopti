--- tests/unit/keyboard/engine/ke_lifecycle/test_ready_token.lua

--- ==============================================================================
--- MODULE: Karabiner Ready Notification Generation Guard
--- DESCRIPTION:
--- Proves that a delayed READY banner belongs to one exact live lease token and
--- cannot outlive disable, stop, failure or replacement by another generation.
--- ==============================================================================

local helpers = require("tests.helpers")

local function load_lifecycle()
	local ctx = {
		phase = "active",
		token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		timers = {},
		notifications = 0,
	}
	package.loaded["keyboard.adapters.karabiner.ke_lifecycle"] = nil
	package.loaded["keyboard.adapters.karabiner.lease_controller"] = {
		status = function()
			return ctx.phase, { phase = ctx.phase, token = ctx.token }
		end,
	}
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["core.ui.engine.notifications"] = {
		notify = function() ctx.notifications = ctx.notifications + 1 end,
	}
	package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
	package.loaded["core.text.engine.utils"] = { shell_quote = function(value) return value end }

	local lifecycle = helpers.load_with_stubs("keyboard.adapters.karabiner.ke_lifecycle", {
		settings = { get = function() return true end },
		timer = {
			secondsSinceEpoch = function() return 100 end,
			doAfter = function(_, callback)
				local timer = { callback = callback, stopped = false }
				function timer:stop() self.stopped = true end
				ctx.timers[#ctx.timers + 1] = timer
				return timer
			end,
		},
		execute = function() return "", true end,
		application = { launchOrFocus = function() return true end },
	})
	return lifecycle, ctx
end

helpers.describe("karabiner ready notification is token-scoped", function()
	helpers.it("drops a queued banner when the earning lease is no longer active", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		helpers.assert_eq(#ctx.timers, 1, "READY must schedule one delayed banner")

		ctx.phase = "idle"
		ctx.timers[1].callback()

		helpers.assert_eq(ctx.notifications, 0,
			"a delayed callback must re-check the lease instead of announcing stale readiness")
	end)

	helpers.it("drops a queued banner after generation replacement", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		ctx.token = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		ctx.timers[1].callback()

		helpers.assert_eq(ctx.notifications, 0,
			"READY from an old token cannot describe a replacement generation")
	end)

	helpers.it("emits once when the same exact token remains active", function()
		local lifecycle, ctx = load_lifecycle()
		lifecycle.notify_ready()
		ctx.timers[1].callback()

		helpers.assert_eq(ctx.notifications, 1,
			"the live token that earned READY should retain its notification")
	end)
end)
