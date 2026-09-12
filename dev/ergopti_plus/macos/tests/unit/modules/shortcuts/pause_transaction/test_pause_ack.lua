--- tests/unit/modules/shortcuts/pause_transaction/test_pause_ack.lua

--- ==============================================================================
--- MODULE: Script-Control Pause Ack Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context
local Assertions = require("tests.support.pause_transaction_assertions")
local count_notifications = Assertions.count_notifications

helpers.describe("script-control pause transaction waits for exact lease ACK", function()
	helpers.it("keeps every feature live until paced input is idle and cancels a queued reversal", function()
		with_context({ input_drain_deferred = true }, function(script_control, ctx)

			helpers.assert_true(script_control.pause_all())
			helpers.assert_eq(ctx.calls.input_drain, 1)
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, nil,
				"native pause must not overtake an owned paced replacement")
			helpers.assert_eq(ctx.calls.keymap_pause, nil)
			helpers.assert_eq(script_control.is_paused(), false)

			helpers.assert_true(script_control.resume_all(),
				"a rapid reversal must be accepted while the input drain owns pause")
			ctx.input_idle_callbacks[1]()
			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, nil,
				"the queued resume must cancel pause before native publication")
			helpers.assert_eq(ctx.calls.keymap_pause, nil)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence,
				"a queued resume cancels pause before taking the admission fence")
			script_control.stop()
		end)
	end)

	helpers.it("does not publish or quiesce pause before PAUSED, then commits once", function()
		with_context(nil, function(script_control, ctx)

			script_control.pause_all()
			helpers.assert_not_nil(ctx.admission_fence,
				"the idle callback must close admission before native PAUSED is requested")
			helpers.assert_eq(script_control.is_paused(), false,
				"requesting pause must not publish a committed state")
			helpers.assert_eq(ctx.calls.karabiner_pause, nil,
				"the native transition request must be deferred off the caller/eventtap")
			helpers.assert_eq(ctx.calls.keymap_pause, nil,
				"Hammerspoon submodules must remain in their settled state before PAUSED")
			helpers.assert_eq(#ctx.pause_listener, 0, "listeners must wait for the exact ACK")
			helpers.assert_eq(#ctx.notifications, 0, "success notification must wait for the exact ACK")

			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_pause, 1)
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(ctx.calls.keymap_pause, nil)

			ctx.pause_callback(true, "paused")
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_eq(ctx.calls.keymap_pause, 1)
			helpers.assert_eq(ctx.calls.shortcuts_pause, 1)
			helpers.assert_eq(ctx.calls.gestures_pause, 1)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
			helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
			helpers.assert_not_nil(ctx.admission_fence,
				"committed pause retains the same admission owner until resume")

			ctx.pause_callback(true, "duplicate-paused")
			helpers.assert_eq(ctx.calls.keymap_pause, 1,
				"a duplicated native callback must not commit the pause twice")
			helpers.assert_eq(count_notifications(ctx, "script_control.paused", "warning"), 1)
			script_control.stop()
		end)
	end)
end)
