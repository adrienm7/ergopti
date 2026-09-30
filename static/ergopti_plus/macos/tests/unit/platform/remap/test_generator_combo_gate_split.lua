--- tests/unit/platform/remap/test_generator_combo_gate_split.lua

--- ==============================================================================
--- MODULE: Key Combinations Have Their Own Switch In The Generated Rules
--- DESCRIPTION:
--- The modifier combinations moved from the Tap-Holds submenu to their own
--- « Combinaisons de touches » group under Shortcuts, with its own switch,
--- persisted as [mod_combos] enabled, the only switch they follow (decision
--- of 2026-09-29). An absent flag is on, whatever the Tap-Holds switch says.
---
--- ROOT CAUSE ENCODED:
--- the generator marked every combo rule as a Tap-Holds feature rule, so the
--- Tap-Holds switch alone decided whether combinations were generated: they
--- could be neither kept while the per-key rules were off nor dropped while
--- they were on.
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
	F19_LAYER_NAV_EXITED    = 80,
}

local Generator = helpers.load_with_stubs("platform.remap.generator")
local TOKEN = "0123456789abcdef0123456789abcdef"

local ACTIONS = {
	{ id = "none", label = "Rien", karabiner_to = {} },
	{ id = "cmd", label = "Cmd", karabiner_to = { { key_code = "left_command" } } },
	{ id = "tab", label = "Tab", karabiner_to = { { key_code = "tab" } } },
	{ id = "escape", label = "Échap", karabiner_to = { { key_code = "escape" } } },
}
local KEYS = {
	{ id = "return_or_enter", label = "Enter", from = { key_code = "return_or_enter" } },
	{ id = "escape", label = "Esc", from = { key_code = "escape" } },
}
local COMBOS = {
	{
		id = "esc_ret", label = "Esc + Enter", group = "Esc",
		from = {
			simultaneous = { { key_code = "escape" }, { key_code = "return_or_enter" } },
			simultaneous_options = { key_down_order = "strict" },
		},
	},
}
local COMBO_LABEL = "Esc + Enter"

--- Builds one state with a key and a combination both assigned.
--- @param tap_holds_enabled boolean|nil Tap-Holds switch.
--- @param mod_combos_enabled boolean|nil Key-combinations switch; nil is absent.
--- @return table state
local function make_state(tap_holds_enabled, mod_combos_enabled)
	return {
		tap_holds_enabled = tap_holds_enabled,
		mod_combos_enabled = mod_combos_enabled,
		tap_hold_config = {
			return_or_enter = { tap = "none", hold = "cmd" },
			escape = { tap = "none", hold = "none" },
		},
		mod_combos_config = { esc_ret = { combo = "tab", tap = "escape", hold = "none" } },
		tap_hold_timeout_ms = 200,
		simultaneous_threshold_ms = 100,
		combo_symmetric = false,
	}
end

--- Which feature rules the generator emits for one state.
--- @param state table Generator state.
--- @return table found { combos = number, enter_tap_hold = boolean }
local function generated(state)
	local config, err = Generator.build_karabiner_json(
		state, ACTIONS, KEYS, COMBOS, {}, "/fake/data_dir/", TOKEN)
	helpers.assert_nil(err)
	local found = { combos = 0, enter_tap_hold = false }
	for _, rule in ipairs(config.profiles[1].complex_modifications.rules) do
		local description = tostring(rule.description)
		if description:find(COMBO_LABEL, 1, true) then found.combos = found.combos + 1 end
		for _, manipulator in ipairs(rule.manipulators or {}) do
			for _, event in ipairs(manipulator.to or {}) do
				local variable = event.set_variable
				if variable and tostring(variable.name):find("ke_held_return_or_enter", 1, true) then
					found.enter_tap_hold = true
				end
			end
		end
	end
	return found
end

helpers.describe("key combinations have their own switch in the generated rules", function()
	helpers.it("keeps the combinations when Tap-Holds are off and combinations are on", function()
		local found = generated(make_state(false, true))
		helpers.assert_true(found.combos >= 1, "the combination rules survive Tap-Holds off")
		helpers.assert_eq(found.enter_tap_hold, false, "the per-key rules still go with Tap-Holds")
	end)

	helpers.it("drops only the combinations when they are off and Tap-Holds are on", function()
		local state = make_state(true, false)
		local found = generated(state)
		helpers.assert_eq(found.combos, 0, "no combination rule while the combinations are off")
		helpers.assert_true(found.enter_tap_hold, "the per-key rules stay")
		helpers.assert_eq(state.mod_combos_config.esc_ret.combo, "tab", "every stored pair is kept")
	end)

	helpers.it("reads an absent combinations switch as on, whatever Tap-Holds say (combos-own-switch)", function()
		helpers.assert_true(generated(make_state(true, nil)).combos >= 1, "absent is on with Tap-Holds on")
		helpers.assert_true(generated(make_state(false, nil)).combos >= 1, "absent is on with Tap-Holds off")
		for _, tap_holds in ipairs({ true, false }) do
			helpers.assert_true(Generator.key_combinations_enabled(make_state(tap_holds, nil)))
			helpers.assert_eq(Generator.key_combinations_enabled(make_state(tap_holds, false)), false)
			helpers.assert_eq(Generator.key_combinations_enabled(make_state(tap_holds, true)), true)
		end
	end)
end)
