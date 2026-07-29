--- tests/meta/test_gestures_ghost_timer_guard.lua

--- ==============================================================================
--- MODULE: Gestures Ghost Timer Guard Meta Test
--- DESCRIPTION:
--- Static source guard for the "gesture-engine-ghost-timer" audit finding in
--- modules/gestures/init.lua.
---
--- ROOT CAUSE ENCODED:
--- Two `hs.timer.doAfter` callbacks scheduled during `M.start()` did not guard
--- against `M.stop()` being called before they fired. If the module was stopped
--- quickly after starting (e.g., during a hot-reload), the pending callbacks would
--- fire after teardown and call `kickstart_hid()` + `recycle_watchers()`, which
--- re-attached touchdevice watchers on an otherwise-stopped module, causing the
--- next `M.start()` to find stale watchers and leak resource handles.
---
--- The fix adds `if not CoreState.enabled then return end` at the top of each
--- callback, matching the canonical "was I cancelled?" pattern used elsewhere in
--- this module.
--- ==============================================================================

local helpers = require("tests.helpers")
local DRIVER_ROOT = helpers.driver_root()

local function read_source(rel)
	local fh = io.open(DRIVER_ROOT .. rel, "r")
	assert(fh, "cannot open " .. rel)
	local src = fh:read("*a")
	fh:close()
	return src
end


-- =========================================================================
-- =========================================================================
-- ======= 1/ Safety-probe doAfter guards against disabled CoreState ========
-- =========================================================================
-- =========================================================================

helpers.describe("gestures/init.lua: ghost timer guard (gesture-engine-ghost-timer)", function()

	helpers.it("STARTUP_SAFETY_PROBE_SEC doAfter checks CoreState.enabled before acting", function()
		local src = read_source("modules/gestures/init.lua")
		-- The callback around STARTUP_SAFETY_PROBE_SEC must guard with CoreState.enabled
		-- Pattern: doAfter(STARTUP_SAFETY_PROBE_SEC, function() ... if not CoreState.enabled then return end
		helpers.assert_true(
			src:match("STARTUP_SAFETY_PROBE_SEC.-CoreState%.enabled") ~= nil
			or src:match("CoreState%.enabled[^\n]-\n[^\n]-STARTUP_SAFETY_PROBE_SEC") ~= nil
			or (src:find("if not CoreState.enabled then return end") ~= nil
				and src:find("STARTUP_SAFETY_PROBE_SEC") ~= nil),
			"gestures/init.lua startup safety-probe callback must guard against CoreState.enabled=false (gesture-engine-ghost-timer)")
	end)

	helpers.it("emergency recycle doAfter(0.02) checks CoreState.enabled before acting", function()
		local src = read_source("modules/gestures/init.lua")
		-- The 20ms emergency recycle callback must also guard
		-- Matches the INVARIANT (the callback refuses to act when the engine is not
		-- enabled), not one spelling of it. The guard was later widened to also
		-- refuse while the script is paused, which is strictly stronger — pinning
		-- the exact text made a strengthening look like a regression.
		helpers.assert_true(
			src:find("if not CoreState.enabled then return end") ~= nil
			or src:find("if not CoreState.enabled or CoreState.suspended then return end") ~= nil,
			"gestures/init.lua emergency-recycle callback must guard against CoreState.enabled=false (gesture-engine-ghost-timer)")
	end)

end)
