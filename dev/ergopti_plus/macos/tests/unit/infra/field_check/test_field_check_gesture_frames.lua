--- tests/unit/infra/field_check/test_field_check_gesture_frames.lua

--- ==============================================================================
--- MODULE: Field Run Touch Frame Clock Probe (gesture-frames-field)
--- DESCRIPTION:
--- The gestures engine times touch frames on the trackpad's capture stamp
--- (ledger L46). The Mac confirmation was to read the log for "has no capture
--- timestamp" and the frame spacing; the field run now proves both:
--- 1. the touch callback counts every frame, stamped or not;
--- 2. any unstamped frame fails, no touch at all skips;
--- 3. the mean spacing leaves out the pause between two touches.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.field_check", "infra.field_check_checks", "infra.field_check_probes" }

local function run(counts)
	local result
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["infra.field_check_probes"] = nil
		local Engine = require("infra.field_check")
		assert(Engine.run("gesture_frames", { gesture_frame_counts = function() return counts end },
			function(done) result = done end), "check did not start")
	end)
	helpers.assert_not_nil(result, "the check never finished")
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result
end

helpers.describe("touch frame clock probe (gesture-frames-field)", function()
	helpers.it("passes stamped frames and names their spacing", function()
		local steps, result = run({ stamped = 240, unstamped = 0, mean_spacing_ms = 8.33 })
		helpers.assert_true(result.passed)
		helpers.assert_eq(steps.gesture_frames_stamped.value, "240")
		helpers.assert_eq(steps.gesture_frame_spacing_ms.value, "8.3")
	end)

	helpers.it("fails any frame without a capture stamp", function()
		local steps, result = run({ stamped = 10, unstamped = 3, mean_spacing_ms = 8 })
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.gesture_frames_stamped.value, "unstamped:3")
	end)

	helpers.it("skips when the trackpad was not touched", function()
		local steps, result = run({ stamped = 0, unstamped = 0 })
		helpers.assert_true(result.passed, "no touch proves nothing and fails nothing")
		helpers.assert_eq(steps.gesture_frames_stamped.state, "skip")
	end)
end)

helpers.describe("touch frame evidence (gesture-frames-field)", function()
	helpers.it("the touch watcher counts each frame, stamped or not", function()
		local Evidence = require("infra.gesture_frame_evidence")
		Evidence.reset()
		local with_fixture = require("tests.support.gesture_runtime_fixture").with_fixture
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.start(), true, "the gesture runtime must start")
			helpers.assert_true(watcher:running(), "the touch watcher must run")
			runtime.frame_callback(nil, { {} }, 100.000, 7)
			runtime.frame_callback(nil, { {} }, 100.008, 8)
			runtime.frame_callback(nil, { {} }, nil, 9)
			helpers.assert_eq(gestures.stop(), true, "the owned gesture fixture must retire")
		end)
		local counts = Evidence.counts()
		helpers.assert_eq(counts.stamped, 2)
		helpers.assert_eq(counts.unstamped, 1)
		helpers.assert_true(math.abs(counts.mean_spacing_ms - 8) < 0.001, "two stamps 8 ms apart")
	end)

	helpers.it("leaves the pause between two touches out of the mean", function()
		local Evidence = require("infra.gesture_frame_evidence")
		Evidence.reset()
		Evidence.note(10.0)
		Evidence.note(10.01)
		Evidence.note(25.0)
		Evidence.note(25.02)
		local counts = Evidence.counts()
		helpers.assert_true(math.abs(counts.mean_spacing_ms - 15) < 0.001,
			"10 and 20 ms frames average 15 ms; the 15 s pause is not a frame interval")
		Evidence.reset()
		helpers.assert_nil(Evidence.counts().mean_spacing_ms, "no spacing before two frames")
	end)
end)
