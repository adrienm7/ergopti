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
--- green. This BEHAVIORAL test drives execute_single() and asserts exactly one
--- keystroke with the expected modifiers+key is posted — it fails (0 keystrokes) if
--- sg() ever rebinds the label as the fn.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["lib.logger"] = nil
local _ = helpers.load_with_stubs("lib.logger")
local Actions = helpers.load_with_stubs("modules.gestures.actions")

helpers.describe("gestures.actions: modifier+key actions post the expected keystroke (G1)", function()
	local function assert_single_keystroke(action, expected_mods, expected_key)
		_G.hs.eventtap.__reset()
		Actions.execute_single(action)
		local ks = _G.hs.eventtap.__keystrokes
		helpers.assert_eq(#ks, 1, action .. " must post exactly one keystroke (a label-bound fn would post zero)")
		helpers.assert_eq(ks[1].key, expected_key, action .. " must target key '" .. tostring(expected_key) .. "'")
		local modset = {}
		for _, m in ipairs(ks[1].mods or {}) do modset[m] = true end
		for _, m in ipairs(expected_mods) do
			helpers.assert_true(modset[m] == true, action .. " must include modifier '" .. m .. "'")
		end
	end

	helpers.it("cmd_a posts Cmd+a", function()        assert_single_keystroke("cmd_a", {"cmd"}, "a") end)
	helpers.it("cmd_shift_a posts Cmd+Shift+a", function() assert_single_keystroke("cmd_shift_a", {"cmd", "shift"}, "a") end)
	helpers.it("ctrl_a posts Ctrl+a", function()      assert_single_keystroke("ctrl_a", {"ctrl"}, "a") end)
	helpers.it("option_a posts Option+a", function()  assert_single_keystroke("option_a", {"alt"}, "a") end)
end)
