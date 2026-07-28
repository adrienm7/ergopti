--- tests/unit/modules/test_three_silent_defects.lua

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

helpers.describe("input-source upgrade: the script returns a parseable count", function()
	helpers.it("coerces both counts to text before concatenating", function()
		local src = helpers.read_driver_source("upgrade_active_list")
		helpers.assert_true(src ~= nil and src ~= "", "input_sources must be locatable")

		local code = src:gsub("%-%-[^\n]*", "")
		local at = code:find("count of disabled", 1, true)
		helpers.assert_true(at ~= nil, "the script must still report its counts")

		local line = code:sub(at - 120, at + 160)
		helpers.assert_true(line:find("as text", 1, true) ~= nil,
			"AppleScript's & on two non-string operands builds a LIST, so the payload arrived as "
				.. "\"1, /, 2\" and the parser below saw no match at all — reporting every "
				.. "successful upgrade as a failure")
	end)

	helpers.it("the parser accepts the corrected payload and rejects a failed run", function()
		-- The verdict logic, exercised directly: this is the shape the script now
		-- emits, and the shape a genuinely failed upgrade emits.
		local function parse(out)
			local _disabled_n, enabled_n = tostring(out or ""):match("(%d+)%s*/%s*(%d+)")
			return tonumber(enabled_n or 0) and tonumber(enabled_n or 0) > 0
		end

		helpers.assert_true(parse("1/2"),
			"a run that enabled two sources must be read as success")
		helpers.assert_true(not parse("1/0"),
			"a run that disabled the legacy source without enabling its replacement must NOT be "
				.. "success — that leaves the user with no Ergopti layout at all")
		helpers.assert_true(not parse("1, /, 2"),
			"and the LIST form must not parse: pinning that this shape fails is what makes the "
				.. "'as text' coercion load-bearing rather than cosmetic")
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
