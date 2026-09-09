--- tests/unit/modules/shortcuts/pause_transaction/test_admission_release.lua

--- ==============================================================================
--- MODULE: Script-Control Admission Release Tests
--- DESCRIPTION:
--- Exercises transaction ownership through the shared isolated pause fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_context = require("tests.support.pause_transaction_fixture").with_context
local Assertions = require("tests.support.pause_transaction_assertions")
local count_notifications = Assertions.count_notifications

helpers.describe("script-control resume transaction is atomic", function()
	helpers.it("never publishes RESUMED before exact admission release settles", function()
		for _, mode in ipairs({ "false", "throw" }) do
			local options = mode == "false"
				and { admission_release_failures = 1 }
				or { admission_release_throws = 1 }
			with_context(options, function(script_control, ctx)
				script_control.pause_all()
				ctx.fire_deferred()
				ctx.pause_callback(true, "paused")
				local exact_fence = ctx.admission_fence

				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callback(true, "resumed")
				helpers.assert_eq(script_control.is_paused(), true,
					mode .. " admission release must roll local activation back to PAUSED")
				helpers.assert_true(ctx.admission_fence == exact_fence,
					"the exact refused fence remains owned for retry")
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0)
				helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }),
					"listeners may not observe RESUMED before admission reopens")
				helpers.assert_eq(ctx.calls.karabiner_pause, 2,
					"native RESUMED must be rolled back when admission cannot reopen")

				ctx.pause_callbacks[2](true, "re-paused")
				helpers.assert_true(ctx.admission_fence == exact_fence)
				script_control.resume_all()
				ctx.fire_deferred()
				ctx.resume_callbacks[2](true, "retry-resumed")
				helpers.assert_eq(script_control.is_paused(), false)
				helpers.assert_nil(ctx.admission_fence)
				helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 1)
				script_control.stop()
			end)
		end
	end)

	helpers.it("keeps no-integration resume private until the exact fence releases", function()
		with_context({
			integration_enabled = false,
			admission_release_failures = 1,
		}, function(script_control, ctx)
			script_control.pause_all()
			local exact_fence = ctx.admission_fence
			helpers.assert_eq(script_control.is_paused(), true)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))

			script_control.resume_all()
			helpers.assert_eq(script_control.is_paused(), true,
				"local-only resume must roll back when admission release returns false")
			helpers.assert_true(ctx.admission_fence == exact_fence)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true }))
			helpers.assert_eq(count_notifications(ctx, "script_control.resumed", "success"), 0)

			script_control.resume_all()
			helpers.assert_eq(script_control.is_paused(), false)
			helpers.assert_nil(ctx.admission_fence)
			helpers.assert_true(helpers.deep_equal(ctx.pause_listener, { true, false }))
			script_control.stop()
		end)
	end)

end)
