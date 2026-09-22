--- tests/unit/platform/remap/test_generator_tap_holds_switch.lua

--- ==============================================================================
--- MODULE: Tap-Holds Feature Switch In The Generated Karabiner Rules
--- DESCRIPTION:
--- Switching Tap-Holds off must behave like a pause for the per-key rules: the
--- keys fall back to their native behaviour (Enter stays Enter, never `none`)
--- while every stored assignment survives. The right-Command rule is kept, as
--- it carries AltGr and the variable the script-control sentinels read.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

package.loaded["adapters.file_system"] = {
	read = function() return nil end,
	read_with_status = function() return nil, "absent" end,
	write = function() return true end,
}
package.loaded["infra.config_paths"] = {
	get_config_dir = function() return "/tmp/ergopti_test" end,
}
package.loaded["infra.keycodes"] = {
	to_name                 = function(code) return "key_" .. tostring(code) end,
	F13_KARABINER_RETURN    = 105,
	F14_KARABINER_BACKSPACE = 107,
	F15_KARABINER_ESCAPE    = 113,
	F20_LAYER_NAV_ENTERED   = 90,
}

local Generator = helpers.load_with_stubs("platform.remap.generator")
local TOKEN = "0123456789abcdef0123456789abcdef"

local ACTIONS = {
	{ id = "none", label = "Rien", karabiner_to = {} },
	{ id = "cmd", label = "Cmd", karabiner_to = { { key_code = "left_command" } } },
	{ id = "altgr", label = "AltGr", karabiner_to = { { key_code = "right_option" } } },
	{ id = "tab", label = "Tab", karabiner_to = { { key_code = "tab" } } },
}
local KEYS = {
	{ id = "right_command", label = "Right Command", from = { key_code = "right_command" } },
	{ id = "return_or_enter", label = "Enter", from = { key_code = "return_or_enter" } },
}

--- Builds one state with both keys assigned.
--- @param tap_holds_enabled boolean|nil Feature switch.
--- @return table state
local function make_state(tap_holds_enabled)
	return {
		tap_holds_enabled = tap_holds_enabled,
		tap_hold_config = {
			right_command = { tap = "tab", hold = "altgr" },
			return_or_enter = { tap = "none", hold = "cmd" },
		},
		mod_combos_config = {},
		tap_hold_timeout_ms = 200,
		simultaneous_threshold_ms = 100,
		combo_symmetric = false,
	}
end

--- Returns whether a manipulator sets the held variable of its own key, which
--- only the tap/hold rule of that key does (the script-control sentinels also
--- match Enter, but only read the right-Command variable).
--- @param manipulator table Generated manipulator.
--- @param key_code string Physical key.
--- @return boolean tracks
local function tracks_own_key(manipulator, key_code)
	for _, event in ipairs(manipulator.to or {}) do
		local variable = event.set_variable
		if variable and tostring(variable.name):find("ke_held_" .. key_code, 1, true) then
			return true
		end
	end
	return false
end

--- Returns the set of physical keys that own a generated tap/hold rule.
--- @param state table Generator state.
--- @return table keys Key code → true.
local function tap_hold_keys_in(state)
	local config, err = Generator.build_karabiner_json(
		state, ACTIONS, KEYS, {}, {}, "/fake/data_dir/", TOKEN)
	helpers.assert_nil(err)
	local found = {}
	for _, rule in ipairs(config.profiles[1].complex_modifications.rules) do
		for _, manipulator in ipairs(rule.manipulators or {}) do
			local from = manipulator.from and manipulator.from.key_code
			if (from == "right_command" or from == "return_or_enter")
				and tracks_own_key(manipulator, from) then
				found[from] = true
			elseif from == "return_or_enter" then
				found.script_control_trigger = true
			end
		end
	end
	return found
end

helpers.describe("Tap-Holds feature switch in the generated rules", function()
	helpers.it("generates every tap/hold rule while the switch is on", function()
		local found = tap_hold_keys_in(make_state(true))
		helpers.assert_true(found.right_command == true)
		helpers.assert_true(found.return_or_enter == true)
	end)

	helpers.it("treats an absent switch as on, like saves older than it", function()
		local found = tap_hold_keys_in(make_state(nil))
		helpers.assert_true(found.return_or_enter == true)
	end)

	helpers.it("keeps only the right-Command rule when the switch is off", function()
		local state = make_state(false)
		local found = tap_hold_keys_in(state)
		helpers.assert_true(found.right_command == true,
			"AltGr and the script-control trigger must survive Tap-Holds off")
		helpers.assert_true(found.script_control_trigger == true,
			"the AltGr+Enter pause trigger must still be generated")
		helpers.assert_nil(found.return_or_enter,
			"Enter must fall back to its native behaviour, not to a `none` rule")
		helpers.assert_eq(state.tap_hold_config.return_or_enter.hold, "cmd",
			"switching off must keep every stored assignment")
	end)
end)
