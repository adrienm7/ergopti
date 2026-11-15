--- tests/unit/platform/remap/generator/test_generator_lone_modifier_tap_window.lua

--- ==============================================================================
--- MODULE: Generator Lone Modifier Tap Window
--- DESCRIPTION:
--- tap_holds.lone_modifier_tap_max_ms widens the Karabiner tap timeout of a
--- key whose hold is a modifier, so a deliberate press of that key alone still
--- types its tap (field report mac-2026-11-03: a 250 ms Shift tap copied
--- nothing). The real generator builds the rules from the shipped catalogues
--- and the Karabiner v16 model of tests/support/karabiner_model.lua replays
--- them: Karabiner's to_if_alone already needs the key alone, so a key pressed
--- under it still makes a hold; 0 is the strict tap-hold; a typing key keeps
--- its own threshold.
--- ==============================================================================

local helpers        = require("tests.helpers")
local KarabinerModel = require("tests.support.karabiner_model")
local SourceFile     = require("tests.support.source_file")

local TOKEN    = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"
local TIMEOUT_PARAMETER = "basic.to_if_alone_timeout_milliseconds"
local COMMAND_FLAGS = { left_command = true, right_command = true }

helpers.with_fresh_modules({
	"core.fs.adapters.file_system",
	"infra.config_paths",
	"platform.input.keycodes",
	"core.logger.engine.logger",
	"core.text.engine.toml.codec",
	"platform.remap.config",
	"platform.remap.generator",
	"modules.keymap.layout_registry",
	"core.text.engine.toml_codec",
}, function()
	package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
	package.loaded["infra.config_paths"] = {
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

	local Config    = helpers.load_with_stubs("platform.remap.config")
	local Generator = helpers.load_with_stubs("platform.remap.generator")

	local actions = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
	local keys    = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
	local combos  = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
	local non_canonical = Config.compute_non_canonical_combos(combos)

	--- Builds the rules with only the given bindings and the given window.
	--- @param window_ms number tap_holds.lone_modifier_tap_max_ms.
	--- @param bindings table Key id -> { tap, hold }.
	--- @return table state
	--- @return table engine A Karabiner model of the generated rules.
	local function build(window_ms, bindings)
		local state = Config.build_default_state(keys, combos)
		state.tap_holds_enabled = true
		state.lone_modifier_tap_max_ms = window_ms
		for id, binding in pairs(bindings) do state.tap_hold_config[id] = binding end
		local config, err = Generator.build_karabiner_json(state, actions, keys, combos, non_canonical, DATA_DIR, TOKEN)
		assert(config, "generation failed: " .. tostring(err))
		local rules = config.profiles[1].complex_modifications.rules
		return state, KarabinerModel.new(rules, { variables = { [Generator.mode_variable_name(TOKEN)] = 1 } })
	end

	--- The tap timeout of the manipulator that takes a key, as Karabiner reads it.
	--- @param engine table Karabiner model.
	--- @param key_code string Physical key.
	--- @return number milliseconds
	local function tap_limit(engine, key_code)
		local manipulator = assert(engine:find(key_code), key_code .. " has no manipulator")
		assert(manipulator.to_if_alone, key_code .. " has no tap")
		return assert(manipulator.parameters and manipulator.parameters[TIMEOUT_PARAMETER],
			key_code .. ": a tap manipulator without its timeout")
	end

	--- Presses key_code, optionally strikes another key under it, and releases it
	--- after hold_ms.
	--- @param engine table Karabiner model.
	--- @param key_code string Physical key.
	--- @param hold_ms number Press duration.
	--- @param under string|nil Key struck while key_code is down.
	--- @return table emissions
	local function press(engine, key_code, hold_ms, under)
		local limit = tap_limit(engine, key_code)
		local down_at = engine.now
		engine:down(key_code)
		if under then
			engine:advance(50)
			engine:down(under)
			engine:up(under, true)
		end
		engine:advance(hold_ms - (engine.now - down_at))
		engine:up(key_code, engine.now - down_at < limit)
		return engine:emissions()
	end

	--- Whether the emissions typed key_code as a tap.
	--- @param emissions table
	--- @param key_code string
	--- @return boolean
	local function tapped(emissions, key_code)
		for _, emission in ipairs(emissions) do
			if emission.phase == "tap" and emission.key_code == key_code then return true end
		end
		return false
	end

	--- Whether `key_code` was typed with Command held.
	--- @param emissions table
	--- @param key_code string
	--- @return boolean
	local function typed_with_command(emissions, key_code)
		for _, emission in ipairs(emissions) do
			if emission.key_code == key_code and emission.phase == "down" then
				for flag in pairs(COMMAND_FLAGS) do
					if emission.flags[flag] then return true end
				end
			end
		end
		return false
	end

	local CAPS = { caps_lock = { tap = "return", hold = "cmd" } }

	helpers.describe("Generator lone modifier tap window (lone-tap-window)", function()
		helpers.it("a modifier key released alone after 600 ms still types its tap (lone-tap-window)", function()
			local _, engine = build(1000, CAPS)
			helpers.assert_eq(tap_limit(engine, "caps_lock"), 1000)
			helpers.assert_true(tapped(press(engine, "caps_lock", 600), "return_or_enter"),
				"a 600 ms lone press is within the 1000 ms window")
		end)

		helpers.it("a key pressed under the modifier key makes a hold, not a tap (lone-tap-window)", function()
			local _, engine = build(1000, CAPS)
			local emissions = press(engine, "caps_lock", 600, "a")
			helpers.assert_eq(tapped(emissions, "return_or_enter"), false, "a chord never types the tap")
			helpers.assert_true(typed_with_command(emissions, "a"), "the key under it is typed with Command")
		end)

		helpers.it("with the window off, a 600 ms press is a hold (lone-tap-window)", function()
			local state, engine = build(0, CAPS)
			helpers.assert_eq(tap_limit(engine, "caps_lock"), state.tap_hold_timeout_ms)
			helpers.assert_true(state.tap_hold_timeout_ms < 600, "control: the shipped threshold is under 600 ms")
			helpers.assert_eq(tapped(press(engine, "caps_lock", 600), "return_or_enter"), false,
				"the strict tap-hold types nothing past its threshold")
		end)

		helpers.it("a window shorter than the key's own delay keeps the delay (lone-tap-window)", function()
			local _, engine = build(500, { caps_lock = { tap = "return", hold = "cmd", timeout_ms = 800 } })
			helpers.assert_eq(tap_limit(engine, "caps_lock"), 800)
		end)

		helpers.it("a typing key keeps its threshold (lone-tap-window)", function()
			local state, engine = build(1000, { spacebar = { tap = "space", hold = "cmd" } })
			helpers.assert_eq(tap_limit(engine, "spacebar"), state.tap_hold_timeout_ms,
				"the space bar's hold waits for its threshold and never takes the window")
		end)
	end)
end)
