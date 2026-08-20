--- tests/unit/modules/gestures/test_actions_keyboard_provenance.lua

--- ==============================================================================
--- MODULE: Gesture Keyboard Provenance Regression Tests
--- DESCRIPTION:
--- Executes every gesture that historically injected a keyboard shortcut via
--- AppleScript and drives the production SyntheticInput broker. Each emitted
--- key pair must carry an exact `action` tag; registry membership or a mocked
--- emitter would not detect an untagged System Events fallback.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_action_fixture")


local function normalized_modifiers(modifiers)
	local copy = {}
	for _, modifier in ipairs(modifiers or {}) do copy[#copy + 1] = modifier end
	table.sort(copy)
	return table.concat(copy, ",")
end


local cases = {
	{ id = "spaces previous axis", axis = true, next = false, key = 123, mods = "ctrl" },
	{ id = "spaces next axis", axis = true, next = true, key = 124, mods = "ctrl" },
	{ id = "space_prev", key = 123, mods = "ctrl" },
	{ id = "space_next", key = 124, mods = "ctrl" },
	{ id = "mission_control", key = 160, mods = "" },
	{ id = "app_expose", key = 125, mods = "ctrl" },
}


helpers.describe("gestures.actions: context navigation has exact action provenance", function()
	for _, case in ipairs(cases) do
		helpers.it(case.id .. " returns one tagged action pair", function()
			package.loaded["modules.gestures.actions"] = nil
			local fixture = Fixture.load("modules.gestures.actions")
			local actions = fixture.subject
			actions.init({ space_wrap = true })
			local epoch_before = fixture.synthetic.current_action_epoch()

			if case.axis then
				actions.execute_axis("spaces", case.next)
			else
				helpers.assert_true(actions.execute_single(case.id),
					case.id .. " must have a live gesture handler")
			end

			local events, down, up = fixture.drain("test.gesture." .. case.id)
			helpers.assert_eq(events[1].key, case.key)
			helpers.assert_eq(events[1].isDown, true)
			helpers.assert_eq(events[2].key, case.key)
			helpers.assert_eq(events[2].isDown, false)
			helpers.assert_eq(normalized_modifiers(events[1].mods), case.mods)
			helpers.assert_eq(down.effect, "action")
			helpers.assert_eq(up.effect, "action")
			helpers.assert_true(down.tag ~= up.tag,
				"key-down and key-up require distinct immutable provenance tags")
			helpers.assert_true(fixture.synthetic.current_action_epoch() ~= epoch_before,
				"context navigation must publish one action boundary")
			helpers.assert_eq(fixture.synthetic.stats().active_transactions, 0,
				"the implicit action transaction must terminate after handoff")
		end)
	end
end)
