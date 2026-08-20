--- tests/unit/modules/keylogger/test_context_tracker_init_contract.lua

--- ==============================================================================
--- MODULE: Context Tracker Initialization Contract Regression Tests
--- DESCRIPTION:
--- Verifies that the stateful context tracker publishes an exact boolean init
--- contract. The keylogger startup transaction now depends on this signal; nil
--- success or a mismatched duplicate would otherwise either reject a valid boot
--- or split callbacks across different state objects.
---
--- FEATURES & RATIONALE:
--- 1. Invalid Dependencies: Every malformed dependency fails explicitly.
--- 2. Idempotent Identity: Only an exact duplicate reports success.
--- 3. Split-State Rejection: A second state or callback cannot replace the live
---    dependency graph behind already-registered async callbacks.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("context tracker init publishes exact dependency identity", function()
	helpers.it("returns false for malformed dependencies before state publication", function()
		package.loaded["modules.keylogger.context_tracker"] = nil
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker")
		local state = {}
		local manager = {}
		local paused = function() return false end
		helpers.assert_eq(tracker.init(nil, manager, paused), false)
		helpers.assert_eq(tracker.init(state, nil, paused), false)
		helpers.assert_eq(tracker.init(state, manager, nil), false)
		helpers.assert_eq(tracker.init(state, manager, paused), true,
			"invalid attempts must not poison a later valid initialization")
	end)

	helpers.it("accepts only an exact duplicate dependency graph", function()
		package.loaded["modules.keylogger.context_tracker"] = nil
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker")
		local state = {}
		local manager = {}
		local paused = function() return false end
		helpers.assert_eq(tracker.init(state, manager, paused), true)
		helpers.assert_eq(tracker.init(state, manager, paused), true,
			"an exact idempotent duplicate must preserve startup success")
		helpers.assert_eq(tracker.init({}, manager, paused), false,
			"a different state object must not split registered callbacks")
		helpers.assert_eq(tracker.init(state, {}, paused), false)
		helpers.assert_eq(tracker.init(state, manager, function() return false end), false)
	end)
end)
