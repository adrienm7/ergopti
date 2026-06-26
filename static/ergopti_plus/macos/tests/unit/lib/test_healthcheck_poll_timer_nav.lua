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
local src_path = helpers.driver_root() .. "ui/healthcheck/core.lua"
local fh = io.open(src_path, "r")
if not fh then error("healthcheck core.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Locate the didFinishNavigation branch.
local nav_pos = src:find('"didFinishNavigation"', 1, true)
helpers.assert_true(nav_pos ~= nil, 'healthcheck.lua must handle "didFinishNavigation" (lib-health-2)')
local nav_body = src:sub(nav_pos, nav_pos + 1200)

-- Test 1: _stop_poll() must appear BEFORE the new _poll_timer assignment.
local stop_pos      = nav_body:find("_stop_poll()", 1, true)
local new_timer_pos = nav_body:find("hs.timer.new(", 1, true)
helpers.assert_true(
	stop_pos ~= nil,
	"didFinishNavigation branch must call _stop_poll() before arming a new poll timer (lib-health-2)"
)
helpers.assert_true(
	new_timer_pos ~= nil,
	"didFinishNavigation branch must create a new poll timer with hs.timer.new (lib-health-2)"
)
helpers.assert_true(
	stop_pos < new_timer_pos,
	"_stop_poll() must be called before hs.timer.new() in didFinishNavigation (lib-health-2)"
)

print("[PASS] test_healthcheck_poll_timer_nav")
