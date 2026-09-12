--- tests/unit/modules/shortcuts/pause_transaction/test_optional_cleanup.lua

--- ==============================================================================
--- MODULE: Script-Control Optional Cleanup Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context
local Assertions = require("tests.support.pause_transaction_assertions")
local count_notifications = Assertions.count_notifications
local has_warning_containing = Assertions.has_warning_containing

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("does not replay one-way PAUSE cleanup after admission release refusal", function()
		for _, owner in ipairs({
			{ step = "keymap_reset", label = "prediction reset" },
			{ step = "tooltip_hide", label = "tooltip dismissal" },
		}) do
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				with_context({ admission_release_failures = 1 }, function(script_control, ctx)
					helpers.assert_true(script_control.pause_all())
					ctx.fire_deferred()
					ctx.pause_callbacks[1](true, "paused")
					helpers.assert_eq(ctx.calls[owner.step], 1,
						"positive control must commit the original " .. owner.label)

					ctx.pause_failure = { step = owner.step, mode = mode }
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[1](true, "native-resumed")
					helpers.assert_eq(ctx.calls[owner.step], 1,
						owner.label .. " was never resumed and must not be acquired again")
					helpers.assert_eq(script_control.is_paused(), true)
					helpers.assert_true(script_control.is_pause_transition_pending(),
						"native re-pause must remain owned until its callback settles")

					ctx.pause_callbacks[2](true, "native-repaused")
					helpers.assert_eq(script_control.is_pause_transition_pending(), false)
					helpers.assert_eq(ctx.calls[owner.step], 1,
						"terminal native compensation may not replay one-way work")
					ctx.pause_failure = nil
					helpers.assert_true(script_control.resume_all())
					ctx.fire_deferred()
					ctx.resume_callbacks[2](true, "retry-resumed")
					helpers.assert_eq(script_control.is_paused(), false)
					helpers.assert_eq(ctx.calls[owner.step], 1)
					helpers.assert_true(script_control.stop())
				end)
			end
		end
	end)

	helpers.it("keeps optional keylogger resync failures outside the activation transaction", function()
		for _, mode in ipairs({ "false", "throw" }) do
			with_context({
				resume_failure = { step = "keylogger_resync", mode = mode },
			}, function(script_control, ctx)
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callbacks[1](true, "paused")

				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callback(true, "resumed")

				helpers.assert_eq(ctx.calls.keylogger_resync, 1,
					"resume must still attempt the optional context refresh")
				helpers.assert_eq(script_control.is_paused(), false,
					"metrics OFF/uninitialized keylogger must not block an otherwise complete resume")
				helpers.assert_eq(ctx.calls.karabiner_pause, 1,
					"a non-activating optional failure must not roll native remapping back")
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
				helpers.assert_eq(count_notifications(ctx, "script_control.resume_failed", "error"), 0)
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
				helpers.assert_true(has_warning_containing(ctx, "keylogger.resync_context"),
					"the optional failure must remain visible in the file logger")
				script_control.stop()
			end)
		end
	end)

	helpers.it("serializes a rapid pause then resume without overlapping native input", function()
		with_context(nil, function(script_control, ctx)
			script_control.pause_all()
			script_control.resume_all()
			ctx.fire_deferred()

			helpers.assert_eq(ctx.calls.karabiner_pause, 1)
			helpers.assert_eq(ctx.calls.karabiner_resume, nil,
				"the reversal must wait for PAUSED instead of overlapping controller input")
			ctx.pause_callback(true, "paused")
			helpers.assert_eq(script_control.is_paused(), true)

			ctx.fire_deferred()
			helpers.assert_eq(ctx.calls.karabiner_resume, 1)
			ctx.resume_callback(true, "resumed")
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_eq(ctx.calls.keymap_pause, 1)
			helpers.assert_eq(ctx.calls.keymap_resume, 1)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
			script_control.stop()
		end)
	end)
end)
