--- tests/unit/modules/dynamic_hotstrings/rules_engine/test_match_buffer_guard_cost.lua

--- ==============================================================================
--- MODULE: Regression — a keystroke asks the section guard only for suffix hits
--- DESCRIPTION:
--- The dynamic-rule preview provider runs on every keystroke. match_buffer
--- asked the section guard of every rule before testing its suffix, and the
--- keymap's guard reads the settings store natively: the preview providers cost
--- 1.7 ms per key on average in the 2026-10-30 macOS field report. The suffix
--- test now comes first; a disabled section still never matches.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads a fresh shared engine with the date rules and two @-tags.
local function engine()
	package.loaded["dynamic_hotstrings"] = nil
	local Engine = require("dynamic_hotstrings")
	Engine.register_date_rules("\u{2605}")
	assert(Engine.add_rule("@e", "personal", function() return "mail" end))
	assert(Engine.add_rule("@p", "personal", function() return "name" end))
	return Engine
end

helpers.describe("dynamic_hotstrings.match_buffer section guard cost", function()
	helpers.it("does not consult the guard while typing ordinary text", function()
		local Engine, calls = engine(), 0
		local function guard() calls = calls + 1; return true end
		for _, buffer in ipairs({ "", "b", "bonjour", "la réunion de demain", "x@", "€" }) do
			helpers.assert_eq(Engine.match_buffer(buffer, "dynamic", guard, true), nil, buffer)
		end
		helpers.assert_eq(calls, 0, "no rule suffix matched, so no guard read is needed")
	end)

	helpers.it("asks the guard of the matching rule and still honours a disabled section", function()
		local Engine, asked = engine(), {}
		local enabled = true
		local function guard(group, section)
			asked[#asked + 1] = group .. "/" .. section
			return enabled
		end
		local match = Engine.match_buffer("contact @e", "dynamic", guard, true)
		helpers.assert_eq(match and match.result, "mail")
		helpers.assert_eq(table.concat(asked, ","), "dynamic/personal")
		enabled = false
		helpers.assert_eq(Engine.match_buffer("contact @e", "dynamic", guard, true), nil,
			"a disabled section must not match")
		helpers.assert_eq(Engine.match_buffer("@p", "dynamic", nil, true).result, "name",
			"a missing guard keeps every section enabled")
	end)
end)
