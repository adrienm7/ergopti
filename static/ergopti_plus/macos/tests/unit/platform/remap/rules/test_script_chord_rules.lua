--- tests/unit/platform/remap/rules/test_script_chord_rules.lua

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

package.loaded["core.logger.engine.logger"] = nil
helpers.load_with_stubs("core.logger.engine.logger")
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

	-- On Ergopti+ right Option types symbols: a fast « (# » then Return while
	-- it was still held paused the driver (the maintainer, 2026-11-17). A
	-- chord is right Option pressed, then its key, as on Windows and Linux.
	-- The keys run through the deployed rules as Karabiner takes them: the
	-- first manipulator whose key and conditions match takes the key-down.
	helpers.it("script-chord-sequence: only the key right after right Option is a chord", function()
		local actions = {
			NONE_ACTION,
			{ id = "altgr", label = "AltGr", karabiner_to = { { key_code = "right_option" } } },
			{ id = "tab", label = "Tab", karabiner_to = { { key_code = "tab" } } },
			{ id = "cmd", label = "Cmd", karabiner_to = { { key_code = "left_command" } } },
		}
		local keys = {
			{ id = "right_command", label = "Right Command", from = { key_code = "right_command" } },
			{ id = "spacebar", label = "Space", from = { key_code = "spacebar" } },
		}
		local config, err = Generator.build_karabiner_json({
			tap_hold_config = { right_command = { tap = "tab", hold = "altgr" },
				spacebar = { tap = "none", hold = "cmd" } },
			mod_combos_config = {}, tap_hold_timeout_ms = 200,
			simultaneous_threshold_ms = 100, combo_symmetric = false,
		}, actions, keys, {}, {}, "/fake/data_dir/", TEST_LEASE_TOKEN)
		helpers.assert_nil(err)
		local rules = config.profiles[1].complex_modifications.rules

		--- The keys Karabiner posts for a stream of { key, down } presses.
		local function play(stream)
			local vars, taken, posted, held = {}, {}, {}, {}
			local function holds(condition)
				local logical = LeaseContract.parse_runtime_variable_name(condition.name)
				-- The lease's own mode and revocation gates are open in this deploy.
				if not logical then return LeaseContract.is_managed_variable_name(condition.name) end
				local equal = (vars[condition.name] or 0) == condition.value
				if condition.type == "variable_if" then return equal end
				if condition.type == "variable_unless" then return not equal end
				return false
			end
			local function matches(manipulator, key)
				local from = manipulator.from or {}
				if manipulator.type ~= "basic" or from.key_code ~= key then return false end
				for _, name in ipairs((from.modifiers or {}).mandatory or {}) do
					if not held[name] then return false end
				end
				for _, condition in ipairs(manipulator.conditions or {}) do
					if not holds(condition) then return false end
				end
				return true
			end
			local function run(events)
				for _, event in ipairs(events or {}) do
					local gate = true
					for _, condition in ipairs(event.conditions or {}) do gate = gate and holds(condition) end
					if gate and event.set_variable then vars[event.set_variable.name] = event.set_variable.value end
					if gate and event.key_code then posted[#posted + 1] = event.key_code end
				end
			end
			for _, step in ipairs(stream) do
				local key, down = step[1], step[2]
				held[key] = down or nil
				if down then
					local found
					for _, rule in ipairs(rules) do
						for _, manipulator in ipairs(rule.manipulators) do
							if not found and matches(manipulator, key) then found = manipulator end
						end
					end
					taken[key] = found
					if found then run(found.to) else posted[#posted + 1] = key end
				elseif taken[key] then
					run(taken[key].to_after_key_up)
					taken[key] = nil
				end
			end
			return posted[#posted]
		end
		local RCMD, RETURN = "right_command", "return_or_enter"
		local chord = play({ { RCMD, true }, { RETURN, true } })
		helpers.assert_true(chord ~= RETURN, "right Option then Return is the pause chord")
		helpers.assert_eq(play({ { RCMD, true }, { "5", true }, { "5", false }, { RETURN, true } }), RETURN,
			"a symbol typed under right Option, then Return, is text")
		helpers.assert_eq(play({ { RCMD, true }, { "spacebar", true }, { "spacebar", false }, { RETURN, true } }),
			RETURN, "a key with its own rule ends the sequence too")
		helpers.assert_eq(play({ { RCMD, true }, { "left_shift", true }, { RETURN, true } }), RETURN,
			"a modifier pressed after right Option ends the sequence")
		helpers.assert_eq(play({ { RCMD, true }, { RETURN, true }, { RETURN, false }, { RETURN, true } }), RETURN,
			"a second Return under the same right Option is text")
		helpers.assert_eq(play({ { RCMD, true }, { "5", true }, { RCMD, false }, { RCMD, true }, { RETURN, true } }),
			chord, "pressed again, right Option starts a new sequence")
		helpers.assert_true(play({ { RCMD, true }, { "fn", true }, { "delete_or_backspace", true } })
			~= "delete_or_backspace", "fn joins the Delete chord of a Mac keyboard without the key")
		helpers.assert_eq(play({ { "5", true } }), "5", "the key ending the sequence still types")
		helpers.assert_eq(play({ { RCMD, true }, { "5", true } }), "5", "the key ending the sequence still types")
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
