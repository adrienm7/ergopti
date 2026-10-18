--- tests/meta/regressions/test_three_silent_defects.lua

--- ==============================================================================
--- MODULE: Regression — three defects that reported the wrong answer
---         (silent-defects-2026-07-22)
--- DESCRIPTION:
--- Each of these produced a confident, wrong result rather than an error.
---
--- ROOT CAUSE ENCODED:
---   1. The input-source list upgrade returned `(count of disabled) & "/" &
---      (count of enabled)`. AppleScript's & on two NON-STRING operands builds a
---      LIST, so osascript printed "1, /, 2" and the Lua pattern expecting "1/2"
---      matched nothing. enabled_n stayed nil, the > 0 test failed, and every
---      SUCCESSFUL upgrade was reported to the user as a failure.
---   2. menu_state's custom-terminator restore was gated on `enabled_ct`, a name
---      never assigned anywhere — an undefined global, so always nil, so the
---      branch never ran. A custom terminator the user had DISABLED came back
---      enabled on every restart.
---   3. The sustained-peak override extended its held span whenever the current
---      count equalled the peak, including after a DIP. Four fingers, then
---      three, then four again measured as one long hold, so two momentary
---      spikes could promote a finger count the user never sustained.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================================
-- ================================================================
-- ======= 1/ The upgrade reports what actually happened ==========
-- ================================================================
-- ================================================================

helpers.describe("input-source upgrade: the native helper returns a parseable count", function()
	helpers.it("uses the typed native transaction instead of the crashing AppleScript bridge", function()
		local src = helpers.read_driver_source("upgrade_active_list_async")
		helpers.assert_true(src ~= nil and src ~= "", "input_sources must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		helpers.assert_true(code:find("InputSourceSelector.upgrade(replacements)", 1, true) ~= nil,
			"the typed helper owns native mutation and canonical count serialization")
		helpers.assert_nil(code:find("TISCreateInputSourceList", 1, true),
			"the former Carbon dictionary bridge must not be reconstructed in Lua")
	end)

	helpers.it("the actual count grammar accepts native counts and rejects the former list form", function()
		local src = helpers.read_driver_source("upgrade_active_list_async")
		helpers.assert_true(src ~= nil and src ~= "", "input_sources must be locatable")
		local pattern = src:match('out_text:match%("(.-)"%)')
		helpers.assert_not_nil(pattern, "the production result grammar must be present")
		for _, case in ipairs({ { text = "1/2", enabled = 2 }, { text = "1/0", enabled = 0 },
			{ text = "1, /, 2" }, { text = "garbage1/2" }, { text = "1/2garbage" } }) do
			local _, enabled = case.text:match(pattern)
			helpers.assert_eq(tonumber(enabled), case.enabled,
				"the real result grammar must preserve the native count payload")
		end
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 2/ The custom-terminator restore actually runs =========
-- ================================================================
-- ================================================================

helpers.describe("menu_state: a disabled custom terminator stays disabled", function()
	helpers.it("resolves the persisted state instead of an undefined global", function()
		local src = helpers.read_driver_source("add_custom_terminator")
		helpers.assert_true(src ~= nil and src ~= "", "menu_state must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("enabled_ct", 1, true)
		helpers.assert_true(at ~= nil, "the custom-terminator restore must still exist")

		-- The name must be DECLARED, not merely referenced. An undefined global
		-- reads as nil forever, so the branch it guards is dead code that looks
		-- exactly like working code.
		helpers.assert_true(code:find("local enabled_ct", 1, true) ~= nil,
			"enabled_ct was never assigned anywhere — an undefined global, always nil, so the "
				.. "branch never ran and a custom terminator the user had disabled came back "
				.. "enabled on every restart")

		local decl_at = code:find("local enabled_ct", 1, true)
		local decl = code:sub(decl_at, decl_at + 200)
		helpers.assert_true(decl:find("terminator_states", 1, true) ~= nil,
			"and it must resolve from the persisted terminator states — the same store the loop "
				.. "above reads, which cannot apply to a custom key that does not exist yet")
	end)
end)




-- ================================================================
-- ================================================================
-- ======= 3/ A dipped peak is not a sustained one ================
-- ================================================================
-- ================================================================

helpers.describe("gestures: two spikes with a dip are not a held peak", function()
	helpers.it("restarts the held span when the peak is re-attained", function()
		local src = helpers.read_driver_source("peakNFirstSeen")
		helpers.assert_true(src ~= nil and src ~= "", "the gesture engine must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("elseif n == gs.peakN then", 1, true)
		helpers.assert_true(at ~= nil, "the peak-extension branch must exist")

		local body = code:sub(at, at + 500)
		helpers.assert_true(body:find("gs.lastN == gs.peakN", 1, true) ~= nil,
			"the span may only be extended while the peak is CONTINUOUSLY held. gs.lastN still "
				.. "holds the previous frame here, so a mismatch means the peak was dropped and "
				.. "re-attained — two momentary spikes, which the unconditional extension "
				.. "measured as one long hold")
		helpers.assert_true(body:find("gs.peakNFirstSeen = now", 1, true) ~= nil,
			"and re-attainment must restart the span, so each spike is judged on the time it was "
				.. "actually held rather than inheriting the first one's start")
	end)
end)
