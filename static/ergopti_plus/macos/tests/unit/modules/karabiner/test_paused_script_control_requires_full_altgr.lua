--- tests/unit/modules/karabiner/test_paused_script_control_requires_full_altgr.lua

--- ==============================================================================
--- MODULE: Regression — paused script-control rules require the FULL AltGr chord
--- DESCRIPTION:
--- Audit finding F-H6. build_paused_script_control_rules() iterated
--- mods = { "right_command", "option" } and emitted ONE rule per modifier with
--- mandatory = { mod }. The "option" iteration produced a rule whose only
--- mandatory modifier was the side-agnostic "option", so ANY plain
--- Option+Backspace/Enter/Escape (the standard macOS editing chords, no
--- right_command at all) matched a sentinel and KE emitted the tagged F13/F14/F15.
--- On the HS side sentinel_is_genuine accepts the tagged sentinel, so the
--- keystroke was swallowed AND the script silently un-paused — and Option+Escape
--- maps to script_quit, so a plain editing chord could QUIT the app while paused.
---
--- Root cause encoded structurally: every paused rule's from.modifiers.mandatory
--- must contain BOTH "right_command" AND "option" (the genuine AltGr chord), and
--- no rule may gate on a single bare modifier. A regression that re-broadens the
--- matcher to a lone modifier fails at the declaration level.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")

local Generator = helpers.load_with_stubs("modules.karabiner.generator")


-- Returns a set { mod = true } for a mandatory-modifier list.
local function as_set(list)
	local s = {}
	for _, m in ipairs(list or {}) do s[m] = true end
	return s
end

helpers.describe("paused script-control rules require right_command + option together", function()
	helpers.it("every paused sentinel rule gates on BOTH right_command AND option", function()
		local rules = Generator.build_paused_script_control_rules()
		helpers.assert_true(#rules > 0, "expected at least one paused script-control rule")

		for _, rule in ipairs(rules) do
			local mand = rule.manipulators[1].from.modifiers.mandatory
			local set  = as_set(mand)
			helpers.assert_true(set["right_command"] == true,
				"a paused rule is missing mandatory 'right_command' — plain Option would match")
			helpers.assert_true(set["option"] == true,
				"a paused rule is missing mandatory 'option'")
			helpers.assert_eq(#mand, 2)
		end
	end)

	helpers.it("NO paused rule gates on a single bare modifier", function()
		local rules = Generator.build_paused_script_control_rules()
		for _, rule in ipairs(rules) do
			local mand = rule.manipulators[1].from.modifiers.mandatory
			-- A length-1 mandatory list is exactly the bug: { "option" } alone matches
			-- plain Option chords; { "right_command" } alone matches plain rcmd chords.
			helpers.assert_true(#mand ~= 1,
				"a paused rule gates on a single bare modifier — re-introduces the plain-Option-un-pauses bug")
		end
	end)
end)
