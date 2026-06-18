--- tests/unit/lib/test_updater_boot_timer_tracked.lua

--- Regression test for lib-update-01: the one-shot boot-check timer created
--- by start_background_checks() was not tracked in any variable, so
--- stop_background_checks() could not cancel it. After a call to
--- stop_background_checks() the timer continued to fire, triggering a
--- background_tick on a channel that was supposed to be stopped.
---
--- Fix: the boot-check timer is stored in module-level _boot_timer; both
--- start_background_checks() and stop_background_checks() manage it.

local helpers = require("tests.helpers")

local src_path = helpers.driver_root() .. "lib/updater.lua"
local fh = io.open(src_path, "r")
if not fh then error("lib/updater.lua not readable at: " .. src_path) end
local src = fh:read("*a") ; fh:close()

-- Test 1: _boot_timer must be declared at module level.
local decl_pos = src:find("local _boot_timer", 1, true)
helpers.assert_true(
	decl_pos ~= nil,
	"lib/updater.lua must declare _boot_timer at module level (lib-update-01)"
)

-- Test 2: doAfter result must be assigned to _boot_timer (not discarded).
local assign_pos = src:find("_boot_timer = hs.timer.doAfter(", 1, true)
helpers.assert_true(
	assign_pos ~= nil,
	"lib/updater.lua must assign the doAfter() result to _boot_timer (lib-update-01)"
)

-- Test 3: stop_background_checks must stop and nil _boot_timer.
local stop_pos = src:find("_boot_timer:stop()", 1, true)
helpers.assert_true(
	stop_pos ~= nil,
	"lib/updater.lua stop_background_checks() must stop _boot_timer (lib-update-01)"
)

print("[PASS] test_updater_boot_timer_tracked")
