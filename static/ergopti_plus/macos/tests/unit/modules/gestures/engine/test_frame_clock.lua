--- tests/unit/modules/gestures/engine/test_frame_clock.lua

--- ==============================================================================
--- MODULE: Gestures frame clock (three-finger-swipe-stuck)
--- DESCRIPTION:
--- The frame clock places a touch frame on the awake timeline at its capture
--- time. A burst of queued frames keeps its real spacing, a time never runs
--- ahead of its delivery, and a device stamp that regresses or stalls
--- re-anchors instead of freezing gesture time.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh frame clock module.
--- @return table FrameClock
local function load()
	package.loaded["modules.gestures.frame_clock"] = nil
	return require("modules.gestures.frame_clock")
end

helpers.describe("gestures frame clock (three-finger-swipe-stuck)", function()
	helpers.it("keeps the spacing of frames delivered in one burst", function()
		local clock = load().new()
		-- A promptly delivered frame anchors the stamp on the awake clock.
		clock.capture(5.000, 1000.001)
		-- Then 35 frames captured 8 ms apart are processed within 2 ms.
		local first = clock.capture(5.008, 1000.290)
		local last
		for i = 2, 35 do last = clock.capture(5.000 + i * 0.008, 1000.290 + i * 0.00005) end
		helpers.assert_true(math.abs((last - first) - 34 * 0.008) < 1e-9,
			"capture spacing must survive a burst: " .. tostring(last - first))
		helpers.assert_true(last <= 1000.290 + 35 * 0.00005, "a frame time never runs ahead of its delivery")
	end)

	helpers.it("times a frame without a stamp at its delivery", function()
		local clock = load().new()
		local time, anchored = clock.capture(nil, 42.5)
		helpers.assert_eq(time, 42.5, "no stamp means delivery time")
		helpers.assert_eq(anchored, false, "and says so")
	end)

	helpers.it("re-anchors on a device stamp that runs backward", function()
		local clock = load().new()
		clock.capture(500.0, 1000.0)
		clock.capture(500.1, 1000.1)
		-- The device restarted and its clock began again near zero.
		local time, anchored = clock.capture(0.2, 1000.3)
		local later = clock.capture(0.3, 1000.4)
		helpers.assert_eq(anchored, false, "a regression re-anchors")
		helpers.assert_true(time <= 1000.3 and math.abs(later - time - 0.1) < 1e-9,
			"time keeps advancing after the device clock reset: " .. tostring(later - time))
	end)

	helpers.it("re-anchors a stamp that lags its delivery beyond the bound", function()
		local FrameClock = load()
		local clock = FrameClock.new()
		clock.capture(10.0, 1000.0)
		local stalled = 1000.0 + FrameClock.MAX_LAG_SEC + 5
		local time, anchored = clock.capture(10.01, stalled)
		helpers.assert_eq(anchored, false, "a stamp that stopped advancing is not trusted")
		helpers.assert_eq(time, stalled, "it is timed at delivery")
	end)

	helpers.it("rejects a delivery time that is not a finite number", function()
		local clock = load().new()
		local ok = pcall(clock.capture, 1.0, 0 / 0)
		helpers.assert_eq(ok, false, "the awake clock is the engine's own contract")
	end)
end)

helpers.describe("the touch watcher hands the engine each frame's capture stamp (three-finger-swipe-stuck)", function()
	helpers.it("forwards the device stamp and drops an unusable one", function()
		local with_fixture = require("tests.support.gesture_runtime_fixture").with_fixture
		with_fixture({}, function(gestures, runtime, watcher)
			helpers.assert_eq(gestures.start(), true, "the gesture runtime must start")
			helpers.assert_true(watcher:running(), "the touch watcher must run")
			runtime.frame_callback(nil, { {} }, 123.25, 7)
			runtime.frame_callback(nil, { {} }, nil, 8)
			local stamps = runtime.engine_frame_stamps
			helpers.assert_eq(gestures.stop(), true, "the owned gesture fixture must retire")
			helpers.assert_eq(stamps[1], 123.25, "the frame's capture stamp must reach the engine")
			helpers.assert_eq(stamps[2], false, "a frame without a stamp reaches it as nil")
		end)
	end)
end)
