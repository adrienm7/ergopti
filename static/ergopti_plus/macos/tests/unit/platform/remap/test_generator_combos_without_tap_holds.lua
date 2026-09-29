--- tests/unit/platform/remap/test_generator_combos_without_tap_holds.lua

--- ==============================================================================
--- MODULE: Key Combinations Work Without The Tap-Holds
--- DESCRIPTION:
--- Builds the real rule graph from the shipped catalogues with the Tap-Holds
--- off and the key combinations on, then replays the hold slots through the
--- Karabiner v16.0.0 model (tests/support/karabiner_model.lua): « Hold 1 +
--- tap 2 » and « Hold 1 + hold 2 » type their action. With the Tap-Holds on,
--- the graph is the one the combinations generated before.
---
--- ROOT CAUSE ENCODED:
--- The hold slots of a pair match only while key 1's held variable is set,
--- and only key 1's own tap-hold rule set it: with the Tap-Holds off that rule
--- was dropped, so key 1 + key 2 typed the native keys instead of the action,
--- although the combinations had their own switch on (decision of 2026-09-29:
--- only that switch governs them).
--- ==============================================================================

local helpers        = require("tests.helpers")
local KarabinerModel = require("tests.support.karabiner_model")
local SourceFile     = require("tests.support.source_file")

local TOKEN    = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"

--- Returns the key codes an engine posted at key_down, in order, with the
--- flags each one carried.
--- @param engine table Karabiner model engine.
--- @return table typed { { key_code, flags } }
local function typed(engine)
	local result = {}
	for _, emission in ipairs(engine:emissions()) do
		if emission.phase == "down" and emission.key_code then
			result[#result + 1] = { key_code = emission.key_code, flags = emission.flags }
		end
	end
	return result
end

--- Whether one of the typed keys is key_code, pressed with no modifier flag.
--- @param keys table Result of typed().
--- @param key_code string Expected output key.
--- @return boolean found
local function typed_bare(keys, key_code)
	for _, key in ipairs(keys) do
		if key.key_code == key_code and next(key.flags) == nil then return true end
	end
	return false
end

--- Describes typed keys for a failure message.
--- @param keys table Result of typed().
--- @return string
local function describe(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		local flags = {}
		for flag in pairs(key.flags) do flags[#flags + 1] = flag end
		table.sort(flags)
		parts[#parts + 1] = key.key_code .. "[" .. table.concat(flags, "+") .. "]"
	end
	return table.concat(parts, " ")
end

helpers.with_fresh_modules({
	"adapters.file_system",
	"infra.config_paths",
	"infra.keycodes",
	"infra.logger",
	"infra.toml.codec",
	"platform.remap.config",
	"platform.remap.generator",
	"toml_codec",
}, function()
	package.loaded["infra.logger"] = helpers.make_logger_stub()
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
	local toml_stub = { encode = function() return "" end, decode = function() return {} end }
	package.loaded["toml_codec"] = toml_stub
	package.loaded["infra.toml.codec"] = toml_stub
	package.loaded["adapters.file_system"] = {
		read = SourceFile.read,
		read_with_status = function(path) return SourceFile.read(path), "ok" end,
	}

	local Config    = helpers.load_with_stubs("platform.remap.config")
	local Generator = helpers.load_with_stubs("platform.remap.generator")
	local LeaseContract = require("platform.remap.lease_contract")

	--- The deployed name of a key's held variable: scoped to the generation.
	--- @param key_code string Physical key.
	--- @return string name
	local function held_var(key_code)
		return assert(LeaseContract.runtime_variable_name("ke_held_" .. key_code, TOKEN))
	end

	local actions = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
	local keys    = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
	local combos  = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
	local non_canonical = Config.compute_non_canonical_combos(combos)

	--- Builds a graph from a state.
	--- @param state table Remap state.
	--- @return table rules The generated complex_modifications rules.
	local function rules_of(state)
		local config, err = Generator.build_karabiner_json(
			state, actions, keys, combos, non_canonical, DATA_DIR, TOKEN)
		assert(config, "generation failed: " .. tostring(err))
		return config.profiles[1].complex_modifications.rules
	end

	--- The shipped default state with one pair's slots set.
	--- @param tap_holds boolean|nil Tap-Holds switch.
	--- @param combinations boolean|nil Key-combinations switch; nil is absent.
	--- @param pair string|nil Combo id.
	--- @param slots table|nil { combo, tap, hold }.
	--- @return table state
	local function state_with(tap_holds, combinations, pair, slots)
		local state = Config.build_default_state(keys, combos)
		state.tap_holds_enabled = tap_holds
		state.mod_combos_enabled = combinations
		if pair then state.mod_combos_config[pair] = slots end
		return state
	end

	--- Starts a Karabiner model on an ACTIVE lease.
	--- @param rules table Generated rules.
	--- @return table engine
	local function engine_for(rules)
		return KarabinerModel.new(rules, { variables = { [Generator.mode_variable_name(TOKEN)] = 1 } })
	end

	--- Whether a rule of the graph sets a key's held variable at its key_down.
	--- @param rules table Generated rules.
	--- @param key_code string Physical key.
	--- @return boolean sets
	local function tracks(rules, key_code)
		for _, rule in ipairs(rules) do
			for _, manipulator in ipairs(rule.manipulators or {}) do
				if manipulator.from and manipulator.from.key_code == key_code then
					for _, event in ipairs(manipulator.to or {}) do
						if event.set_variable and event.set_variable.name == held_var(key_code) then return true end
					end
				end
			end
		end
		return false
	end

	--- Counts the rules whose description contains text.
	--- @param rules table Generated rules.
	--- @param text string Plain substring.
	--- @return number count
	local function count(rules, text)
		local found = 0
		for _, rule in ipairs(rules) do
			if tostring(rule.description):find(text, 1, true) then found = found + 1 end
		end
		return found
	end

	helpers.describe("key combinations without the Tap-Holds (combos-without-tap-holds)", function()
		-- A modifier key 1: its native flag is held, and must not reach the action.
		helpers.it("Hold Cmd + hold Tab types the hold action, bare (combos-without-tap-holds)", function()
			local rules = rules_of(state_with(false, true, "lcmd_tab",
				{ combo = "none", tap = "none", hold = "delete_fwd" }))
			local engine = engine_for(rules)
			engine:down("left_command")
			engine:down("tab")
			local keys_typed = typed(engine)
			helpers.assert_true(typed_bare(keys_typed, "delete_forward"),
				"the hold slot types its action without Cmd: " .. describe(keys_typed))
			engine:up("tab")
			engine:up("left_command")
			helpers.assert_eq(engine:variable(held_var("left_command")), 0, "key 1's release clears its variable")
		end)

		helpers.it("Hold Esc + tap Tab types the tap action (combos-without-tap-holds)", function()
			local rules = rules_of(state_with(false, true, "esc_tab",
				{ combo = "none", tap = "arrow_left", hold = "none" }))
			local engine = engine_for(rules)
			engine:down("escape")
			engine:tap("tab")
			local keys_typed = typed(engine)
			helpers.assert_true(typed_bare(keys_typed, "left_arrow"),
				"the tap slot types its action: " .. describe(keys_typed))
			for _, key in ipairs(keys_typed) do
				helpers.assert_true(key.key_code ~= "tab", "Tab is not typed natively: " .. describe(keys_typed))
			end
		end)

		helpers.it("key 1 only tracks its variable and passes through (combos-without-tap-holds)", function()
			local rules = rules_of(state_with(false, true, "lcmd_tab",
				{ combo = "none", tap = "none", hold = "delete_fwd" }))
			local engine = engine_for(rules)
			engine:down("left_command")
			helpers.assert_eq(engine:variable(held_var("left_command")), 1)
			helpers.assert_true(engine:pressed().left_command == true, "Cmd stays a native Cmd")
			engine:up("left_command")
			helpers.assert_eq(engine:variable(held_var("left_command")), 0)
			helpers.assert_eq(tracks(rules, "left_command"), true)
			helpers.assert_eq(tracks(rules, "escape"), false, "a key that is no key 1 of a hold slot stays native")
			helpers.assert_eq(tracks(rules, "tab"), false, "key 2 stays native")
		end)

		helpers.it("with the Tap-Holds on the graph is unchanged by the switch (combos-without-tap-holds)", function()
			local recommended = Config.build_recommended_state(keys, combos)
			recommended.tap_holds_enabled = true
			local absent = rules_of(recommended)
			recommended.mod_combos_enabled = true
			helpers.assert_eq(rules_of(recommended), absent, "an absent switch is on")
		end)

		helpers.it("the combinations switched off generate no combination rule (combos-without-tap-holds)",
			function()
				for _, tap_holds in ipairs({ true, false }) do
					local rules = rules_of(state_with(tap_holds, false, "lcmd_tab",
						{ combo = "escape", tap = "none", hold = "delete_fwd" }))
					helpers.assert_eq(count(rules, "[var-based]"), 0)
					helpers.assert_eq(count(rules, "[chord]"), 0)
					if not tap_holds then
						helpers.assert_eq(tracks(rules, "left_command"), false, "no held variable is tracked for them")
					end
				end
			end)
	end)
end)
