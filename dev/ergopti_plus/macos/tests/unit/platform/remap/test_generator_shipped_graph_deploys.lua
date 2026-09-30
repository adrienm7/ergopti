--- tests/unit/platform/remap/test_generator_shipped_graph_deploys.lua

--- ==============================================================================
--- MODULE: The Shipped Rule Graph Deploys
--- DESCRIPTION:
--- Builds the Karabiner configuration from the shipped catalogues and rule
--- files, as the app does at boot, and hands it to the merge that deploys it:
--- every preset and switch position must pass the merge's own validation, and
--- merging into an existing karabiner.json edits the selected profile only.
--- The JSON files are decoded by the hs stub, which shares equal JSON values
--- the way Hammerspoon's LuaSkin does.
---
--- ROOT CAUSES ENCODED:
--- 1. dev.148 refused every deploy on a Mac with « generated rule 1
---    manipulator 3 has inconsistent managed conditions ». hs.json.decode
---    returned CapsWord's 30 identical conditions lists as one table, and the
---    generation gate appended its two conditions to it once per manipulator
---    (json-shared-tables).
--- 2. No test built the shipped graph and merged it: the generator tests
---    stopped at the build, whose output the merge alone validates.
--- 3. A graph where two manipulators share a table reached the merge and
---    failed there with no hint of the cause; the gate now refuses it where
---    the graph is built.
--- ==============================================================================

local helpers    = require("tests.helpers")
local SourceFile = require("tests.support.source_file")

local TOKEN        = "0123456789abcdef0123456789abcdef"
local DATA_DIR     = helpers.driver_root() .. "platform/remap/data/"
local KARABINER_OUT = "/ergopti-test/karabiner/karabiner.json"

-- A user's own rule, present in two profiles: hs.json.decode returns the two
-- equal rules lists as one table.
local EXISTING_WITH_TWIN_PROFILES = [[{
	"profiles": [
		{ "name": "Work", "selected": false, "complex_modifications": { "rules": [
			{ "description": "User rule", "manipulators": [
				{ "type": "basic", "from": { "key_code": "f18" }, "to": [ { "key_code": "f19" } ] } ] } ] } },
		{ "name": "Default", "selected": true, "complex_modifications": { "rules": [
			{ "description": "User rule", "manipulators": [
				{ "type": "basic", "from": { "key_code": "f18" }, "to": [ { "key_code": "f19" } ] } ] } ] } }
	]
}]]

--- Loads the generator and the shipped catalogues with an existing file.
--- @param existing string|nil Content of karabiner.json; nil when absent.
--- @param json_codec table|nil Replacement adapters.json_codec.
--- @param run function Receives { Generator, Config, actions, keys, combos, non_canonical }.
local function with_generator(existing, json_codec, run)
	helpers.with_fresh_modules({
		"adapters.file_system",
		"adapters.json_codec",
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
			read_with_status = function(path)
				if path == KARABINER_OUT then
					if existing == nil then return nil, "absent" end
					return existing, "ok"
				end
				return SourceFile.read(path), "ok"
			end,
		}
		if json_codec then package.loaded["adapters.json_codec"] = json_codec end

		local Config    = helpers.load_with_stubs("platform.remap.config")
		local Generator = helpers.load_with_stubs("platform.remap.generator")
		local keys      = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
		local combos    = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
		run({
			Generator     = Generator,
			Config        = Config,
			actions       = assert(Config.load_available_actions(DATA_DIR .. "actions.json")),
			keys          = keys,
			combos        = combos,
			non_canonical = Config.compute_non_canonical_combos(combos),
		})
	end)
end

--- Builds the configuration of one shipped preset.
--- @param env table with_generator environment.
--- @param preset string "default" or "recommended".
--- @param tap_holds boolean Tap-Holds switch.
--- @param combinations boolean Key-combinations switch.
--- @return table|nil config, string|nil err, table legacy_rules, table legacy_context
local function build(env, preset, tap_holds, combinations)
	local state = preset == "recommended"
		and env.Config.build_recommended_state(env.keys, env.combos)
		or env.Config.build_default_state(env.keys, env.combos)
	state.tap_holds_enabled = tap_holds
	state.mod_combos_enabled = combinations
	return env.Generator.build_karabiner_json(
		state, env.actions, env.keys, env.combos, env.non_canonical, DATA_DIR, TOKEN)
end

helpers.describe("the shipped rule graph deploys (json-shared-tables)", function()
	for _, preset in ipairs({ "default", "recommended" }) do
		for _, tap_holds in ipairs({ true, false }) do
			for _, combinations in ipairs({ true, false }) do
				local name = string.format(
					"%s preset, Tap-Holds %s, key combinations %s: the merge accepts the build (json-shared-tables)",
					preset, tap_holds and "on" or "off", combinations and "on" or "off")
				helpers.it(name, function()
					with_generator(nil, nil, function(env)
						local config, err, legacy_rules, legacy_context = build(env, preset, tap_holds, combinations)
						helpers.assert_true(config ~= nil, "build: " .. tostring(err))
						local merged, merge_err = env.Generator.merge_into_existing_config(
							config, KARABINER_OUT, legacy_rules, legacy_context)
						helpers.assert_true(merged ~= nil, "merge: " .. tostring(merge_err))
					end)
				end)
			end
		end
	end

	helpers.it("merging edits the selected profile only, even when another one is equal (json-shared-tables)", function()
		with_generator(EXISTING_WITH_TWIN_PROFILES, nil, function(env)
			local config, err, legacy_rules, legacy_context = build(env, "recommended", true, true)
			helpers.assert_true(config ~= nil, "build: " .. tostring(err))
			local merged, merge_err = env.Generator.merge_into_existing_config(
				config, KARABINER_OUT, legacy_rules, legacy_context)
			helpers.assert_true(merged ~= nil, "merge: " .. tostring(merge_err))
			local work_rules = merged.profiles[1].complex_modifications.rules
			helpers.assert_eq(#work_rules, 1, "the unselected profile keeps its one rule")
			helpers.assert_eq(work_rules[1].description, "User rule")
			helpers.assert_true(#merged.profiles[2].complex_modifications.rules > 1,
				"the selected profile receives the managed rules")
		end)
	end)

	helpers.it("a graph whose manipulators share a table is refused where it is built (json-shared-tables)", function()
		-- The codec as it was: hs.json.decode's graph passed through unchanged.
		local sharing_codec = {
			decode = function(raw) return hs.json.decode(raw), nil end,
			encode = function(value) return hs.json.encode(value), nil end,
		}
		with_generator(nil, sharing_codec, function(env)
			local config, err = build(env, "default", true, true)
			helpers.assert_eq(config, nil, "the build is refused")
			helpers.assert_true(tostring(err):find("shares a table with an earlier manipulator", 1, true) ~= nil,
				"the error names the shared table: " .. tostring(err))
		end)
	end)
end)
