--- tests/unit/modules/keymap/test_llm_bridge_choke_point.lua

--- ==============================================================================
--- MODULE: llm_bridge injection choke-point structural regression test
--- DESCRIPTION:
--- Structural assertions that encode the F-INFO-1 architectural invariant:
--- every prediction replacement MUST route through
--- expander.perform_text_replacement(). The legacy tracker names below remain
--- negative guards: none may be reintroduced as a second provenance path.
---
--- RATIONALE:
--- The single-choke-point rule keeps exact Quartz tags, logical logging and
--- engine state in one transaction. Legacy inline tracker mutations inside
--- apply_prediction are the regression signature — detect them here before they
--- reach a live keyboard.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==================================================================
-- ==================================================================
-- ======= 1/ Source Assertions =====================================
-- ==================================================================
-- ==================================================================

helpers.describe("llm_bridge: F-INFO-1 injection choke-point structural invariants", function()

	local function read_source()
		local f = io.open("modules/keymap/llm_bridge.lua", "r")
		helpers.assert_true(f ~= nil, "modules/keymap/llm_bridge.lua must be readable")
		local src = f:read("*a")
		f:close()
		return src
	end


	helpers.it("calls expander.perform_text_replacement inside apply_prediction", function()
		local src = read_source()
		helpers.assert_true(
			src:find("expander%.perform_text_replacement", 1, false) ~= nil,
			"llm_bridge must call expander.perform_text_replacement (choke-point routing)"
		)
	end)


	helpers.it("does NOT directly write expected_synthetic_deletes outside perform_text_replacement", function()
		local src = read_source()
		-- The only legitimate writes to these counters must come through the choke
		-- point (expander.lua). Any direct assignment in llm_bridge is a regression.
		-- Allow the comment that *mentions* the field (as documentation) — block
		-- actual assignment patterns: "= X" following the field name.
		local pattern = "expected_synthetic_deletes%s*="
		local idx = src:find(pattern)
		helpers.assert_true(
			idx == nil,
			"llm_bridge must not assign expected_synthetic_deletes directly — route through expander.perform_text_replacement"
		)
	end)


	helpers.it("does NOT directly write expected_synthetic_chars outside perform_text_replacement", function()
		local src = read_source()
		local pattern = "expected_synthetic_chars%s*="
		local idx = src:find(pattern)
		helpers.assert_true(
			idx == nil,
			"llm_bridge must not assign expected_synthetic_chars directly — route through expander.perform_text_replacement"
		)
	end)


	helpers.it("does NOT directly write expected_synthetic_pastes outside perform_text_replacement", function()
		local src = read_source()
		local pattern = "expected_synthetic_pastes%s*="
		local idx = src:find(pattern)
		helpers.assert_true(
			idx == nil,
			"llm_bridge must not assign expected_synthetic_pastes directly — route through expander.perform_text_replacement"
		)
	end)


	helpers.it("does NOT directly update last_synthetic_arm_time outside perform_text_replacement", function()
		local src = read_source()
		local pattern = "last_synthetic_arm_time%s*="
		local idx = src:find(pattern)
		helpers.assert_true(
			idx == nil,
			"llm_bridge must not assign last_synthetic_arm_time directly — route through expander.perform_text_replacement"
		)
	end)


	helpers.it("requires the expander module at the top of the file", function()
		local src = read_source()
		helpers.assert_true(
			src:find('require%("modules%.keymap%.expander"%)', 1, false) ~= nil,
			"llm_bridge must require modules.keymap.expander (needed for choke-point call)"
		)
	end)

end)
