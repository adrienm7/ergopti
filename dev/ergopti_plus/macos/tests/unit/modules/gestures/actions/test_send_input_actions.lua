--- tests/unit/modules/gestures/actions/test_send_input_actions.lua

--- ==============================================================================
--- MODULE: send_text / send_key / send_shortcut type and press exactly (macOS)
--- DESCRIPTION:
--- A binding holding a send_* action stores its text, key or shortcut as the
--- binding's parameter; dispatching it goes through the synthetic-input
--- adapter, the one choke point that tags every synthetic event with its
--- provenance, with the exact keys: primary is Command here, a named key is its
--- Hammerspoon name, a text or a lone character is typed as text. A binding
--- without a valid value sends nothing.
---
--- ROOT CAUSE ENCODED:
--- No action could type a chosen text or press a chosen key or shortcut.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.gesture_actions_fixture")
local it = Fixture.it

--- @param keys table calls.keys entries { mods, key }.
--- @return string "mod+mod:key / …"
local function describe_keys(keys)
	local out = {}
	for _, entry in ipairs(keys) do
		out[#out + 1] = table.concat(entry.mods or {}, "+") .. ":" .. tostring(entry.key)
	end
	return table.concat(out, " / ")
end

helpers.describe("send input gesture actions (send-input-actions)", function()
	it("send_shortcut presses the modifiers and the key, primary as Command", function(fresh_actions)
		local actions, calls = fresh_actions()
		actions.init({ action_params = {} })
		for _, value in ipairs({ "ctrl+a", "primary+a", "primary+super+Z", "alt+F4", "shift+tab" }) do
			helpers.assert_eq(actions.set_action_parameter("tap_key__number_row_right_2", "send_shortcut", value),
				true, value .. " must be accepted")
			helpers.assert_eq(actions.execute_single("send_shortcut", "tap_key__number_row_right_2"), true)
		end
		helpers.assert_eq(describe_keys(calls.keys),
			"ctrl:a / cmd:a / cmd:z / alt:f4 / shift:tab",
			"primary and super are both Command on macOS and collapse into one")
		helpers.assert_eq(#calls.typed, 0, "a shortcut types nothing")
	end)

	it("send_key presses a named key and types a character", function(fresh_actions)
		local actions, calls = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter("tap_3", "send_key", "Enter"), true)
		actions.execute_single("send_key", "tap_3")
		helpers.assert_eq(actions.set_action_parameter("tap_3", "send_key", "Del"), true)
		actions.execute_single("send_key", "tap_3")
		helpers.assert_eq(actions.set_action_parameter("tap_3", "send_key", "É"), true)
		actions.execute_single("send_key", "tap_3")
		helpers.assert_eq(describe_keys(calls.keys), ":return / :forwarddelete")
		helpers.assert_eq(table.concat(calls.typed, " / "), "É",
			"a character key is typed as that character, capital kept")
	end)

	it("send_text types the stored text, and nothing without one", function(fresh_actions)
		local actions, calls = fresh_actions()
		actions.init({ action_params = {} })
		helpers.assert_eq(actions.set_action_parameter("tap_key__number_row_right_1", "send_text",
			"bonjour cela va bien?"), true)
		helpers.assert_eq(actions.execute_single("send_text", "tap_key__number_row_right_1"), true)
		helpers.assert_eq(actions.set_action_parameter("tap_3", "send_text", "a\nb"), false,
			"a line break must be refused at assignment")
		actions.execute_single("send_text", "tap_3")
		helpers.assert_eq(table.concat(calls.typed, " / "), "bonjour cela va bien?")
		helpers.assert_eq(#calls.keys, 0)
	end)
end)
