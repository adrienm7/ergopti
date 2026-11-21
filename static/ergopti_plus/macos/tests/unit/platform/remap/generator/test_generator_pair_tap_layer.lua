--- tests/unit/platform/remap/generator/test_generator_pair_tap_layer.lua

--- ==============================================================================
--- MODULE: Generator Pair Tap and the Navigation Layer
--- DESCRIPTION:
--- A pair's tap struck under the navigation layer its first key holds runs out
--- of the layer, which comes back after the action while the first key still
--- holds it, as the Linux engine (combination_lift / combination_restore) and
--- Windows (_KeyCombinationRunOutOfLayer) do: maintainer decision THD-1 of
--- 2026-11-21. Before it, the macOS pair rules left layer_active set around the
--- action. The real generator builds the rules from the shipped catalogues
--- (left Command holds the layer) and the Karabiner v16 model replays them.
--- ==============================================================================

local helpers        = require("tests.helpers")
local KarabinerModel = require("tests.support.karabiner_model")
local SourceFile     = require("tests.support.source_file")

local TOKEN    = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"
local TIMEOUT_PARAMETER = "basic.to_if_alone_timeout_milliseconds"
local F19, F20 = "key_80", "key_90"

helpers.with_fresh_modules({
	"core.fs.adapters.file_system",
	"settings.engine.paths",
	"platform.input.keycodes",
	"core.logger.engine.logger",
	"core.text.engine.toml.codec",
	"platform.remap.config",
	"platform.remap.generator",
	"modules.keymap.layout_registry",
	"core.text.engine.toml_codec",
}, function()
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["settings.engine.paths"] = {
		get_config_dir = function() return "/tmp/ergopti_test" end,
	}
	package.loaded["platform.input.keycodes"] = {
		to_name                 = function(code) return "key_" .. tostring(code) end,
		F13_KARABINER_RETURN    = 105,
		F14_KARABINER_BACKSPACE = 107,
		F15_KARABINER_ESCAPE    = 113,
		F20_LAYER_NAV_ENTERED   = 90,
		F19_LAYER_NAV_EXITED    = 80,
	}
	-- The catalogues read here are JSON and the shared defaults use the
	-- pure-Lua reader; the native TOML codec is absent from the headless runner.
	local toml_stub = { encode = function() return "" end, decode = function() return {} end }
	package.loaded["core.text.engine.toml_codec"] = toml_stub
	package.loaded["core.text.engine.toml.codec"] = toml_stub
	local file_cache = {}
	local function read_once(path)
		if file_cache[path] == nil then file_cache[path] = SourceFile.read(path) end
		return file_cache[path]
	end
	package.loaded["core.fs.adapters.file_system"] = {
		read = read_once,
		read_with_status = function(path) return read_once(path), "ok" end,
	}
	package.loaded["modules.keymap.layout_registry"] =
		require("tests.support.active_layout_registry_fixture").new("ergopti", "iso")

	local Config        = helpers.load_with_stubs("platform.remap.config")
	local Generator     = helpers.load_with_stubs("platform.remap.generator")
	local LeaseContract = require("platform.remap.lease_contract")
	local LAYER = assert(LeaseContract.runtime_variable_name("layer_active", TOKEN))

	local actions = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
	local keys    = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
	local combos  = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
	local non_canonical = Config.compute_non_canonical_combos(combos)

	--- Builds the deployed rules, left Command holding the layer as shipped.
	--- @param pairs_config table Combo id -> { combo, tap, hold }.
	--- @return table rules
	local function build(pairs_config)
		local state = Config.build_default_state(keys, combos)
		state.tap_holds_enabled = true
		state.lone_modifier_tap_max_ms = 0
		state.tap_hold_config.left_command = { tap = "backspace", hold = "layer" }
		for id, slots in pairs(pairs_config) do state.mod_combos_config[id] = slots end
		local config, err = Generator.build_karabiner_json(state, actions, keys, combos, non_canonical, DATA_DIR, TOKEN)
		assert(config, "generation failed: " .. tostring(err))
		return config.profiles[1].complex_modifications.rules
	end

	--- A Karabiner model of rules on an ACTIVE lease.
	--- @param rules table
	--- @return table engine
	local function engine_for(rules)
		return KarabinerModel.new(rules, { variables = { [Generator.mode_variable_name(TOKEN)] = 1 } })
	end

	--- Releases key_code, inside its tap timeout.
	--- @param engine table
	--- @param manipulator table|nil The manipulator that took its press.
	--- @param key_code string
	local function release(engine, manipulator, key_code)
		local limit = manipulator and manipulator.parameters and manipulator.parameters[TIMEOUT_PARAMETER] or math.huge
		engine:up(key_code, KarabinerModel.TAP_MS < limit)
	end

	--- The posted key codes, in order, of the given phase (nil for every phase).
	--- @param engine table
	--- @return table codes
	local function keys_posted(engine)
		local codes = {}
		for _, emission in ipairs(engine:emissions()) do
			if emission.key_code then codes[#codes + 1] = emission.key_code end
		end
		return codes
	end

	--- The index of key_code in list, nil when absent.
	local function index_of(list, key_code)
		for index, value in ipairs(list) do if value == key_code then return index end end
		return nil
	end

	helpers.describe("Generator pair tap out of the navigation layer (pair-tap-layer-restored)", function()
		helpers.it("a release-judged pair tap lifts the layer around its action and gives it back (pair-tap-layer-restored)", function()
			local engine = engine_for(build({ lcmd_caps = { combo = "none", tap = "return", hold = "cmd" } }))
			engine:down("left_command")
			helpers.assert_eq(engine:variable(LAYER), 1, "left Command holds the layer")
			engine:clear()
			local manipulator = engine:down("caps_lock")
			engine:advance(KarabinerModel.TAP_MS)
			release(engine, manipulator, "caps_lock")
			local posted = keys_posted(engine)
			local exit_at, action_at, enter_at = index_of(posted, F19), index_of(posted, "return_or_enter"),
				index_of(posted, F20)
			helpers.assert_not_nil(action_at, "the pair's tap runs")
			helpers.assert_true(exit_at ~= nil and exit_at < action_at, "the layer is lifted before the action")
			helpers.assert_true(enter_at ~= nil and enter_at > action_at, "the layer comes back after the action")
			helpers.assert_eq(engine:variable(LAYER), 1, "the layer left Command still holds is on again")
			engine:up("left_command", false)
			helpers.assert_eq(engine:variable(LAYER), 0, "left Command's release ends the layer")
		end)

		helpers.it("a pair tap after its first key's release turns no layer on (pair-tap-layer-restored)", function()
			local engine = engine_for(build({ lcmd_caps = { combo = "none", tap = "return", hold = "cmd" } }))
			engine:down("left_command")
			local manipulator = engine:down("caps_lock")
			engine:up("left_command", false)
			engine:clear()
			engine:advance(KarabinerModel.TAP_MS)
			release(engine, manipulator, "caps_lock")
			helpers.assert_eq(engine:variable(LAYER), 0, "the released layer stays off")
			helpers.assert_nil(index_of(keys_posted(engine), F20), "no layer entry is signalled")
		end)

		helpers.it("a tap-only pair action runs out of the layer at key-down (pair-tap-layer-restored)", function()
			local engine = engine_for(build({ lcmd_caps = { combo = "none", tap = "capsword", hold = "none" } }))
			engine:down("left_command")
			engine:clear()
			engine:down("caps_lock")
			local posted = keys_posted(engine)
			helpers.assert_true(index_of(posted, F19) ~= nil and index_of(posted, F20) ~= nil,
				"the layer is lifted and given back around the action")
			helpers.assert_eq(engine:variable(LAYER), 1, "the layer is on again at once")
		end)

		helpers.it("a repeating tap-only pair keeps its key down and gives the layer back at its release (pair-tap-layer-restored)", function()
			local engine = engine_for(build({ lcmd_caps = { combo = "none", tap = "return", hold = "none" } }))
			engine:down("left_command")
			engine:down("caps_lock")
			helpers.assert_true(engine:held().return_or_enter == true, "the action's key stays down to repeat")
			helpers.assert_eq(engine:variable(LAYER), 0, "the layer is lifted while the action's key is held")
			engine:up("caps_lock", false)
			helpers.assert_eq(engine:variable(LAYER), 1, "the layer comes back at the second key's release")
			-- First key released first: nothing to give back.
			engine:down("caps_lock")
			engine:up("left_command", false)
			engine:up("caps_lock", false)
			helpers.assert_eq(engine:variable(LAYER), 0, "a layer released meanwhile stays off")
		end)
	end)
end)
