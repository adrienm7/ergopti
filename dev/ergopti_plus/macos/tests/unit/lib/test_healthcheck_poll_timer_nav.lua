--- tests/unit/lib/test_healthcheck_poll_timer_nav.lua

--- Regression test for lib-health-2: healthcheck.lua navigationCallback armed
--- a new poll timer on every didFinishNavigation event without stopping the
--- previous one. A second navigation event (re-navigation or webview redraw)
--- orphaned the old timer, leaving two 200 ms timers polling simultaneously.
---
--- Fix: call _stop_poll() at the top of the didFinishNavigation branch before
--- creating the new poll timer.

local helpers = require("tests.helpers")

-- After the F2 split, the navigationCallback / poll-timer logic lives in core.lua.
-- Selected by a declaration unique to ui/healthcheck/core.lua rather than by
-- path, so moving or splitting the module cannot turn this invariant
-- into a path error.
local src = helpers.read_driver_source("local function _stop_poll")
helpers.assert_true(src ~= nil, "ui/healthcheck/core.lua source must be locatable")

-- Locate the didFinishNavigation branch.
local nav_pos = src:find('"didFinishNavigation"', 1, true)
helpers.assert_true(nav_pos ~= nil, 'healthcheck.lua must handle "didFinishNavigation" (lib-health-2)')

-- The poll timer is armed with the FIRST TimerScheduler.every(...) at or after the
-- branch marker. Anchor to that call rather than a fixed-size character window:
-- the window heuristic is brittle (any code inserted between the branch marker
-- and the timer — e.g. the copy-button JS injection — silently pushes the
-- _stop_poll() call out of range), whereas anchoring to the actual timer-arming
-- site checks the real ordering invariant regardless of how much code precedes it.
local new_timer_pos = src:find("TimerScheduler.every(", nav_pos, true)
helpers.assert_true(
	new_timer_pos ~= nil,
	"didFinishNavigation branch must acquire a recurring timer through TimerScheduler (lib-health-2)"
)

-- _stop_poll() must appear between the branch marker and the timer arming, so a
-- re-navigation stops the previous timer before creating a new one.
local stop_pos = src:find("_stop_poll()", nav_pos, true)
helpers.assert_true(
	stop_pos ~= nil,
	"didFinishNavigation branch must call _stop_poll() before arming a new poll timer (lib-health-2)"
)
helpers.assert_true(
	stop_pos < new_timer_pos,
	"_stop_poll() must be called before TimerScheduler.every() in didFinishNavigation (lib-health-2)"
)

print("[PASS] test_healthcheck_poll_timer_nav")
