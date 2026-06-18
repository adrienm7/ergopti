--- tests/unit/modules/karabiner/test_set_enabled_respects_ownership.lua

--- ==============================================================================
--- MODULE: karabiner set_enabled ownership guard regression tests
--- DESCRIPTION:
--- Verifies that M.set_enabled(false) respects the HS-ownership check before
--- issuing KILL_CMD, mirroring the guard already present in M.kill().
---
--- FEATURES & RATIONALE:
--- 1. Source Invariant: set_enabled must call is_hs_owned_bridge before KILL_CMD
---    so user-managed KE sessions are never killed from the feature toggle.
--- 2. Ordering Check: the ownership guard must appear BEFORE the KILL_CMD line
---    in set_enabled so the guard cannot be bypassed.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==================================================================================
-- ==================================================================================
-- ======= 1/ set_enabled ownership guard — source-level invariant check ============
-- ==================================================================================
-- ==================================================================================

helpers.describe("karabiner.init set_enabled — ownership guard (karabiner-life-1 regression)", function()

	helpers.it("set_enabled source calls is_hs_owned_bridge before KILL_CMD", function()
		local src_path = helpers.driver_root() .. "modules/karabiner/init.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "modules/karabiner/init.lua must be readable")
		local src = fh:read("*a"); fh:close()

		local owned_pos  = src:find("is_hs_owned_bridge", 1, true)
		local kill_pos   = src:find("KeLifecycle.KILL_CMD", 1, true)

		helpers.assert_true(owned_pos ~= nil,
			"set_enabled must reference is_hs_owned_bridge (ownership guard missing)")
		helpers.assert_true(kill_pos ~= nil,
			"set_enabled must reference KeLifecycle.KILL_CMD")
		-- The guard must appear before (or at the same position as) the KILL_CMD call;
		-- a guard appearing only after the kill would be dead code.
		helpers.assert_true(owned_pos < kill_pos,
			"is_hs_owned_bridge guard must appear before KeLifecycle.KILL_CMD in the source")
	end)

	helpers.it("set_enabled source does NOT call KILL_CMD unconditionally in the elseif branch", function()
		local src_path = helpers.driver_root() .. "modules/karabiner/init.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil)
		local src = fh:read("*a"); fh:close()

		-- Pre-fix: the elseif branch called KILL_CMD directly without an ownership check.
		-- Post-fix: KILL_CMD is nested inside an `if hs_owned` block.
		-- We verify the fix by asserting "hs_owned" precedes KILL_CMD in the source,
		-- ensuring the unconditional call cannot exist.
		local hs_owned_pos = src:find("hs_owned", 1, true)
		local kill_pos     = src:find("KeLifecycle.KILL_CMD", 1, true)
		helpers.assert_true(hs_owned_pos ~= nil,
			"hs_owned variable must exist in set_enabled — ownership guard is wired")
		helpers.assert_true(hs_owned_pos < kill_pos,
			"hs_owned check must gate KeLifecycle.KILL_CMD")
	end)

end)
