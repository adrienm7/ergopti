--- tests/unit/platform/remap/layout/test_revoke_settles_once.lua

--- ==============================================================================
--- MODULE: Karabiner Revocation Settles Once Regression Tests
--- DESCRIPTION:
--- When both halves of a revocation (onboarding stop and lease stop) answer
--- inside the call itself, the join already settles the public callback. The
--- trailing join after the lease request must not settle it a second time: the
--- 2026-10-27 field session logged « Duplicate Ergopti Karabiner revocation
--- completion ignored » on every reload for this ordinary synchronous path.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_remap = require("tests.support.activation_layout_fixture").with_remap

--- Counts the logged messages at one level that contain a fragment.
--- @param calls table Fixture observations.
--- @param level string Logger level.
--- @param fragment string Plain text to find.
--- @return integer count
local function count_logged(calls, level, fragment)
	local count = 0
	for _, entry in ipairs(calls.logs) do
		if entry.level == level and entry.message:find(fragment, 1, true) then count = count + 1 end
	end
	return count
end





-- ================================================
-- ================================================
-- ======= 1/ One Settlement Per Revocation =======
-- ================================================
-- ================================================

helpers.describe("Karabiner revocation settlement", function()
	helpers.it("settles the public callback once when both halves answer synchronously", function()
		with_remap({ enabled = true, paused = true, initial_phase = "paused" }, function(remap, calls)
			local results = {}
			helpers.assert_true(remap.revoke("hammerspoon_reload", function(ok, reason)
				results[#results + 1] = { ok = ok, reason = reason }
			end))
			calls.drain_until(function() return #results >= 1 end)
			helpers.assert_eq(#results, 1, "the revocation callback must run exactly once")
			helpers.assert_eq(count_logged(calls, "warn", "Duplicate Ergopti Karabiner revocation"), 0,
				"a synchronous completion is not a duplicate")
		end)
	end)
end)
