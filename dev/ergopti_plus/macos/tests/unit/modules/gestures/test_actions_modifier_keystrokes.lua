--- tests/unit/modules/gestures/test_actions_modifier_keystrokes.lua

--- ==============================================================================
--- MODULE: Regression — modifier+key gesture/shortcut actions actually fire (G1)
--- DESCRIPTION:
--- The sg() registrar was called in a 3-arg form sg(name, label, fn) for every
--- modifier+letter/digit/special-key action, but its 2-arg signature bound the
--- LABEL string as the action's fn. execute_single() guards `type(s.fn) ~=
--- "function"` and silently skips, so EVERY cmd_*/hs_ctrl_*/hs_option_* action was
--- a dead no-op (G1). The fix made sg() accept the optional label.
---
--- The existing test only asserts SG_NAMES membership (built from the shared TOML
--- order, independent of whether fn is a function), so a 2-arg revert would keep it
--- green. This BEHAVIORAL test drives execute_single() through the production
--- tagged broker and asserts exactly one action pair with the expected chord.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.synthetic_action_fixture")

local fixture = Fixture.load("modules.gestures.actions")
local Actions = fixture.subject

helpers.describe("gestures.actions: modifier+key actions post the expected keystroke (G1)", function()
	local function assert_single_keystroke(action, expected_mods, expected_key)
		helpers.assert_true(Actions.execute_single(action),
			action .. " must have a callable handler")
		local events, down, up = fixture.drain("test.modifier." .. action)
		helpers.assert_eq(events[1].key, expected_key,
			action .. " must target key '" .. tostring(expected_key) .. "'")
		local modset = {}
		for _, m in ipairs(events[1].mods or {}) do modset[m] = true end
		for _, m in ipairs(expected_mods) do
			helpers.assert_true(modset[m] == true, action .. " must include modifier '" .. m .. "'")
		end
		helpers.assert_eq(down.effect, "action")
		helpers.assert_eq(up.effect, "action")
	end

	helpers.it("cmd_a posts Cmd+a", function()        assert_single_keystroke("cmd_a", {"cmd"}, "a") end)
	helpers.it("cmd_shift_a posts Cmd+Shift+a", function() assert_single_keystroke("cmd_shift_a", {"cmd", "shift"}, "a") end)
	helpers.it("ctrl_a posts Ctrl+a", function()      assert_single_keystroke("ctrl_a", {"ctrl"}, "a") end)
	helpers.it("option_a posts Option+a", function()  assert_single_keystroke("option_a", {"alt"}, "a") end)
end)
