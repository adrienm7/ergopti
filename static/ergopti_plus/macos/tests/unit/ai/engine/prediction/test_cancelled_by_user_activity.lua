--- tests/unit/ai/engine/prediction/test_cancelled_by_user_activity.lua

--- ==============================================================================
--- MODULE: Prediction Cancelled By User Activity
--- DESCRIPTION:
--- Predictions run only while the user does nothing (maintainer decision
--- 2026-11-06). Any pointer, focus or non-tooltip key activity revokes the
--- request in flight in O(1) inside the eventtap, so its late answer is
--- dropped, then settles the native cleanup: the backend stream is cancelled
--- and the surface hidden. A request left alone completes and shows.
--- ==============================================================================

local helpers = require("tests.helpers")
local Pipeline = require("tests.support.prediction_pipeline")


local function deliver(fixture)
	fixture.on_success({ {
		to_type = " completion", deletes = 0,
		chunks = { { type = "insert", text = " completion" } }, nw = "",
	} }, 25, true, false)
end


helpers.describe("prediction engine — user activity cancels pending work", function()
	helpers.it("reports nothing pending before a request", function()
		local fixture = Pipeline.load({ render_success = true })
		helpers.assert_eq(fixture.engine.has_pending_work(), false)
		helpers.assert_eq(fixture.engine.revoke_for_activity(), nil, "an idle engine has nothing to revoke")
	end)

	helpers.it("cancels a request in flight and drops its late answer", function()
		local fixture = Pipeline.load({ render_success = true })
		fixture.engine.perform_check(true)
		helpers.assert_eq(fixture.fetches, 1)
		helpers.assert_true(fixture.engine.has_pending_work(), "a dispatched request is pending work")
		local token = fixture.engine.revoke_for_activity()
		helpers.assert_true(type(token) == "number", "the revocation returns its settle token")
		helpers.assert_eq(fixture.engine.has_pending_work(), false, "later pointer events read one false flag")
		local hides_before = fixture.hides
		helpers.assert_true(fixture.engine.settle_activity_cancel(token))
		helpers.assert_true(fixture.cancels >= 1, "the backend stream is cancelled")
		helpers.assert_true(fixture.hides > hides_before, "the surface is hidden")
		deliver(fixture)
		helpers.assert_eq(fixture.prediction_renders, 0, "the late answer is never shown")
		helpers.assert_eq(fixture.engine.is_visible(), false)
	end)

	helpers.it("hides a shown prediction", function()
		local fixture = Pipeline.load({ render_success = true })
		fixture.engine.perform_check(true)
		deliver(fixture)
		helpers.assert_true(fixture.engine.is_visible(), "an undisturbed answer is shown")
		helpers.assert_true(fixture.engine.has_pending_work(), "a shown prediction is pending work")
		local token = fixture.engine.revoke_for_activity()
		helpers.assert_true(fixture.engine.settle_activity_cancel(token))
		helpers.assert_eq(fixture.engine.is_visible(), false)
	end)

	helpers.it("shows the answer when the user stays idle", function()
		local fixture = Pipeline.load({ render_success = true })
		fixture.engine.perform_check(true)
		deliver(fixture)
		helpers.assert_eq(fixture.prediction_renders >= 1, true)
		helpers.assert_true(fixture.engine.is_visible())
		helpers.assert_eq(fixture.cancels, 0, "nothing is cancelled without activity")
	end)
end)
