--- tests/unit/modules/llm/test_api_remote_progressive_reveal.lua

--- ==============================================================================
--- MODULE: Regression — the remote backend's progressive reveal must be reachable
--- DESCRIPTION:
--- The remote backend revealed all of its predictions at once instead of one slot
--- at a time, so it behaved differently from Ollama and MLX for no stated reason.
---
--- ROOT CAUSE ENCODED:
--- The guard read `if not is_batch and #results > 1 then`, but every path that
--- reaches this callback sets is_batch — the branch was dead code. The sibling
--- dispatchers guard on `not streaming`, which is a TAUTOLOGY for a backend that
--- never streams, and that operand was mis-ported here as `not is_batch`, which is
--- a contradiction instead. The reveal loop below it, its timings and its
--- `not is_final` argument were all correct and simply never ran.
---
--- Nothing failed and nothing was logged: the user saw the whole prediction list
--- appear in one step and had no reason to think a feature was missing.
---
--- The guard asserts the condition is no longer contradictory. A behavioural test
--- would have to drive a full HTTP round-trip through the remote adapter to reach
--- one branch of one callback, and the reveal loop it gates is already covered by
--- the sibling backends' tests.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==============================================
-- ==============================================
-- ======= 1/ The Reveal Branch Can Run =========
-- ==============================================
-- ==============================================

helpers.describe("api_remote progressive reveal is reachable", function()
	helpers.it("does not gate the reveal on a condition that is always false", function()
		-- Selected by a declaration unique to modules/llm/api_remote.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function load_api_providers")
		helpers.assert_true(src ~= nil, "modules/llm/api_remote.lua source must be locatable")
		if not src then return end

		-- Strip comments: the fix explains the old condition in prose above the code.
		local code = src:gsub("%-%-[^\r\n]*", "")

		helpers.assert_true(code:find("if not is_batch and #results > 1 then") == nil,
			"the reveal must not be gated on `not is_batch`: every path reaching this "
			.. "callback sets is_batch, so the branch was dead and the remote backend "
			.. "revealed every prediction at once instead of one slot at a time")

		helpers.assert_true(code:find("if #results > 1 then") ~= nil,
			"the reveal must run whenever there is more than one result, matching the "
			.. "sibling dispatchers whose `not streaming` operand is a tautology for a "
			.. "backend that never streams")
	end)
end)
