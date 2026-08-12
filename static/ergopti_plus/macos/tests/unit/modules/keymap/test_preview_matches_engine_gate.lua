--- tests/unit/modules/keymap/test_preview_matches_engine_gate.lua

--- ==============================================================================
--- MODULE: Regression — the preview must agree with the engine about what can
---         fire (preview-matches-engine-gate)
--- DESCRIPTION:
--- Two ways the tooltip promised an expansion the engine would refuse.
---
--- ROOT CAUSE ENCODED:
---   1. After an expansion the engine is hard-blocked for the rescan-suppression
---      window, but the preview kept walking the static mappings and offering
---      rows the whole time. The user pressed the validation key, nothing
---      happened, and the window then wiped the buffer — the trigger was lost
---      with no way to retry it short of retyping the word.
---   2. The row's lifetime came from a coarse three-way key (STAR_TRIGGER /
---      autocorrection / dynamichotstrings) while the engine resolves each
---      mapping through a precedence chain that also honours per-section
---      overrides and user-overridden group delays. The two could not help but
---      disagree: a row vanishing while its trigger was still live, or lingering
---      after it had expired.
---
--- The delay chain now has ONE implementation, on CoreState, consumed by both
--- the tap and the preview — a second copy is precisely how they drifted.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 1/ One delay chain, two consumers ======================
-- ================================================================
-- ================================================================

helpers.describe("delay resolution: the engine and the preview share one chain", function()
	helpers.it("CoreState owns the resolver and applies the full precedence", function()
		local State = helpers.load_with_stubs("modules.keymap.state")
		helpers.assert_eq(type(State.new), "function", "CoreState must expose its factory")

		local s = State.new(
			{ expansion_delay = 0.5 },
			{ autocorrection = 0.3, dynamichotstrings = 0.4 })
		helpers.assert_eq(type(s.resolve_mapping_delay), "function",
			"CoreState must own the delay chain, so the tap and the preview cannot each carry "
				.. "their own version of it")

		s.DELAYS.STAR_TRIGGER = 0.9
		s.DELAYS.autocorrection = 0.3
		s.SECTION_DELAYS["comma_j"] = 5.0

		helpers.assert_eq(s.resolve_mapping_delay({ has_magic = true }), 0.9,
			"a star trigger takes the star delay")
		helpers.assert_eq(s.resolve_mapping_delay({ group = "autocorrection", section = "comma_j" }), 5.0,
			"a per-section override outranks the group delay — the coarse three-way key the "
				.. "preview used could not see this at all, so its row expired 4.7 s before the "
				.. "trigger did")

		-- A group delay differing from its default counts as a user override and
		-- wins over the section value.
		s.DELAYS.autocorrection = 1.5
		helpers.assert_eq(s.resolve_mapping_delay({ group = "autocorrection", section = "comma_j" }), 1.5,
			"a user-overridden group delay outranks the section value")

		helpers.assert_eq(s.resolve_mapping_delay({}), 0.5,
			"and an unqualified mapping falls back to the base delay")

		local live, remaining = s.mapping_delay_remaining({}, 0.2, 1)
		helpers.assert_eq(live, true)
		helpers.assert_eq(remaining, 0.3)
		local at_deadline, zero_remaining = s.mapping_delay_remaining({}, 0.5, 1)
		helpers.assert_eq(at_deadline, false,
			"the engine must expire at the same >= boundary as tooltip dequeue")
		helpers.assert_eq(zero_remaining, 0)
		local complex_live, complex_remaining = s.mapping_delay_remaining({}, 0.5, 2)
		helpers.assert_eq(complex_live, true,
			"the shared policy must still expose the wider complex-key window")
		helpers.assert_eq(complex_remaining, 0.5)
		s.BASE_DELAY_SEC = 0
		local infinite, no_deadline = s.mapping_delay_remaining({}, 999, 2)
		helpers.assert_eq(infinite, true)
		helpers.assert_nil(no_deadline,
			"delay zero means always active and must never manufacture an expired deadline")
	end)

	helpers.it("the tap delegates rather than re-implementing", function()
		local src = helpers.read_driver_source("mapping_fires")
		helpers.assert_true(src ~= nil and src ~= "", "the keymap tap must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("local function mapping_fires", 1, true)
		helpers.assert_true(at ~= nil, "mapping_fires must exist")

		local body = code:sub(at, at + 900)
		helpers.assert_true(body:find("mapping_delay_remaining", 1, true) ~= nil,
			"the tap must resolve through CoreState, not inline its own copy of the chain")
		helpers.assert_true(body:find("CoreState.SECTION_DELAYS[m.section]", 1, true) == nil,
			"and the inlined chain must be gone — two implementations is the drift itself")
	end)

	helpers.it("the preview sizes its rows through the same resolver", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		local at = code:find("local function literal_preview_allowed", 1, true)
		helpers.assert_true(at ~= nil, "the literal-collision row lifetime must still be computed")

		local body = code:sub(at, at + 800)
		helpers.assert_true(body:find("mapping_delay_remaining", 1, true) ~= nil,
			"the row's lifetime must come from the chain that decides whether the trigger can "
				.. "still fire, or the tooltip goes on offering an expansion the engine refuses")

		-- The resolver reads section and has_magic, so the rows must carry them.
		helpers.assert_true(code:find("section    = mapping.section", 1, true) ~= nil,
			"and the rows must carry the fields the resolver reads — without them every mapping "
				.. "silently resolves to the group default and the fix is cosmetic")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 2/ No rows while the engine is blocked =================
-- ================================================================
-- ================================================================

helpers.describe("preview: nothing is offered while the engine is suppressed", function()
	helpers.it("skips the static mappings during the rescan-suppression window", function()
		local src = helpers.read_driver_source("_preview_render_generation")
		local code = src:gsub("%-%-[^\n]*", "")

		local at = code:find("engine_blocked", 1, true)
		helpers.assert_true(at ~= nil,
			"the preview must know when the engine is hard-blocked. During the suppression "
				.. "window that follows an expansion no trigger can fire, so every row offered "
				.. "then names a trigger the user cannot use — and the window wipes the buffer, "
				.. "losing it entirely")

		helpers.assert_true(code:find("_state.no_rescan_until", 1, true) ~= nil,
			"read from the same CoreState field the tap tests, so the preview and the engine "
				.. "cannot disagree about whether a trigger is live")

		local walk_at = code:find(
			"not%s+engine_blocked%s+and%s+expander%.resolve_magic_action%(buf,%s*literal_preview_allowed%)")
		helpers.assert_true(walk_at ~= nil,
			"and the shared prospective resolution must actually be gated on it — knowing the engine is "
				.. "blocked while still offering rows changes nothing")
	end)
end)
