--- tests/unit/platform/remap/test_script_chord_rules.lua

--- ==============================================================================
--- MODULE: Regression — Karabiner rules of the shared script chords
--- DESCRIPTION:
--- The script chords are one set on the three drivers
--- (script-chords-three-os-2026-09-30): right Option (the physical right
--- Command the remap turns into it) with Return, Backspace, Delete or Escape.
--- Karabiner turns a chord into its sentinel only while its slot runs an
--- action, so an unassigned slot, every slot while the switch is off and,
--- while paused, every action outside script management reach the
--- application as the plain chord.
---
--- ROOT CAUSE ENCODED:
--- The generator emitted the three historical sentinel rules whatever the
--- slots held: a slot set to "none" still turned right Option + Return into a
--- sentinel nothing ran, and macOS had no Delete chord at all.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")
local Generator = helpers.load_with_stubs("platform.remap.generator")
local LeaseContract = require("platform.remap.lease_contract")
local TEST_LEASE_TOKEN = "0123456789abcdef0123456789abcdef"
local NONE_ACTION = { id = "none", label = "Rien", karabiner_to = {} }

--- The running and paused script rules a state deploys.
--- @param chords table|nil The state's plan.
--- @return table running, table paused, table legacy Rules by description prefix.
local function script_rules(chords)
	local config, err, legacy = Generator.build_karabiner_json({
		tap_hold_config = {}, mod_combos_config = {}, tap_hold_timeout_ms = 200,
		simultaneous_threshold_ms = 100, combo_symmetric = false, script_chords = chords,
	}, { NONE_ACTION }, {}, {}, {}, "/fake/data_dir/", TEST_LEASE_TOKEN)
	helpers.assert_nil(err)
	local running, paused, historical = {}, {}, {}
	-- Deployed rules carry the lease's managed prefix before their description.
	for _, rule in ipairs(config.profiles[1].complex_modifications.rules) do
		if rule.description:find("] Script control: physical rcmd + ", 1, true) then
			running[#running + 1] = rule
		elseif rule.description:find("] Paused script control: option + ", 1, true) then
			paused[#paused + 1] = rule
		end
	end
	for _, rule in ipairs(legacy) do
		if rule.description:find("Script control: physical rcmd + ", 1, true) == 1 then
			historical[#historical + 1] = rule
		end
	end
	return running, paused, historical
end

--- The Karabiner keys a list of rules reads.
local function keys_of(rules)
	local keys = {}
	for _, rule in ipairs(rules) do
		for _, manipulator in ipairs(rule.manipulators) do keys[#keys + 1] = manipulator.from.key_code end
	end
	return table.concat(keys, ",")
end

helpers.describe("Karabiner rules of the shared script chords (script-chords-three-os-2026-09-30)", function()
	helpers.it("script-chord: an empty configuration deploys the four chords, running and paused", function()
		local running, paused = script_rules(nil)
		helpers.assert_eq(#running, 4)
		helpers.assert_eq(#paused, 4)
		helpers.assert_eq(keys_of(running),
			"delete_forward,delete_or_backspace,return_or_enter,delete_or_backspace,escape",
			"the Delete slot comes first: fn + Backspace is the Delete of a Mac keyboard without the key")
		local fn_delete = running[1].manipulators[2]
		helpers.assert_eq(fn_delete.from.modifiers.mandatory[1], "fn")
		helpers.assert_eq(running[1].manipulators[1].to[1].key_code, running[1].manipulators[2].to[1].key_code)
		for _, rule in ipairs(running) do
			for _, manipulator in ipairs(rule.manipulators) do
				local held = false
				-- The lease scopes every runtime variable name to its generation.
				for _, condition in ipairs(manipulator.conditions) do
					local logical, token = LeaseContract.parse_runtime_variable_name(condition.name)
					held = held or (logical == "ke_held_right_command" and token == TEST_LEASE_TOKEN
						and condition.value == 1)
				end
				helpers.assert_true(held, "a running chord reads the held right Command: " .. rule.description)
			end
		end
	end)

	helpers.it("script-chord: a slot without an action keeps its chord native", function()
		local running, paused = script_rules({ normal = { script_altgr_escape = true }, paused = {} })
		helpers.assert_eq(#running, 1)
		helpers.assert_eq(keys_of(running), "escape")
		helpers.assert_eq(#paused, 0, "no paused sentinel either")
	end)

	helpers.it("script-chord: the switch off deploys no chord at all", function()
		local running, paused = script_rules({ normal = {}, paused = {} })
		helpers.assert_eq(#running, 0)
		helpers.assert_eq(#paused, 0)
	end)

	helpers.it("script-chord: paused, only the script-management slots keep a sentinel", function()
		local running, paused = script_rules({
			normal = { script_altgr_enter = true, script_altgr_delete = true },
			paused = { script_altgr_enter = true },
		})
		helpers.assert_eq(keys_of(running), "delete_forward,delete_or_backspace,return_or_enter")
		helpers.assert_eq(keys_of(paused), "return_or_enter")
	end)

	helpers.it("script-chord: the legacy graph proof keeps describing the three historical rules", function()
		local _, _, historical = script_rules({ normal = {}, paused = {} })
		helpers.assert_eq(keys_of(historical), "delete_or_backspace,return_or_enter,escape")
	end)

	helpers.it("script-chord: a plan naming an unknown slot is refused", function()
		local config, err = Generator.build_karabiner_json({
			tap_hold_config = {}, mod_combos_config = {}, tap_hold_timeout_ms = 200,
			simultaneous_threshold_ms = 100, combo_symmetric = false,
			script_chords = { normal = { return_key = true }, paused = {} },
		}, { NONE_ACTION }, {}, {}, {}, "/fake/data_dir/", TEST_LEASE_TOKEN)
		helpers.assert_nil(config)
		helpers.assert_true(tostring(err):find("unknown slot", 1, true) ~= nil, tostring(err))
	end)
end)
