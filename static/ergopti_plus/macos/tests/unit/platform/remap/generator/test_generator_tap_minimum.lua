--- tests/unit/platform/remap/generator/test_generator_tap_minimum.lua

--- ==============================================================================
--- MODULE: Generator Tap Minimum
--- DESCRIPTION:
--- Every tap that waits for its release respects tap_hold.tap_min_duration_ms,
--- the Linux and Windows rule (maintainer decision 2026-11-10): a release
--- sooner than the minimum is a bounce, not a tap. Karabiner's to_if_alone has
--- only a maximum, so the generator gates each tap event on a variable a
--- delayed action raises once the minimum has elapsed. The real generator
--- builds the rules from the shipped catalogues and the Karabiner v16 model of
--- tests/support/karabiner_model.lua replays them. A rollover key keeps no
--- minimum, as the Linux roll keys do.
--- ==============================================================================

local helpers        = require("tests.helpers")
local KarabinerModel = require("tests.support.karabiner_model")
local SourceFile     = require("tests.support.source_file")

local TOKEN    = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"
local TIMEOUT_PARAMETER = "basic.to_if_alone_timeout_milliseconds"
local TAP_MIN_MS = require("infra.timings").ms("tap_hold", "tap_min_duration_ms")

helpers.with_fresh_modules({
	"core.fs.adapters.file_system",
	"infra.config_paths",
	"infra.keycodes",
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
	package.loaded["infra.keycodes"] = {
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

	--- Builds the deployed rules with the given key and pair bindings.
	--- @param bindings table Key id -> { tap, hold }.
	--- @param pairs_config table|nil Combo id -> { combo, tap, hold }.
	--- @return table rules
	local function build(bindings, pairs_config)
		local state = Config.build_default_state(keys, combos)
		state.tap_holds_enabled = true
		state.lone_modifier_tap_max_ms = 0
		for id, binding in pairs(bindings) do state.tap_hold_config[id] = binding end
		for id, slots in pairs(pairs_config or {}) do state.mod_combos_config[id] = slots end
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

	--- Presses key_code alone for hold_ms and releases it.
	--- @param engine table
	--- @param key_code string
	--- @param hold_ms number
	local function press(engine, key_code, hold_ms)
		local manipulator = engine:down(key_code)
		local limit = manipulator and manipulator.parameters and manipulator.parameters[TIMEOUT_PARAMETER] or math.huge
		local down_at = engine.now
		engine:advance(hold_ms)
		engine:up(key_code, engine.now - down_at < limit)
	end

	--- How many times the emissions typed key_code as a tap.
	--- @param engine table
	--- @param key_code string
	--- @return number
	local function taps(engine, key_code)
		local count = 0
		for _, emission in ipairs(engine:emissions()) do
			if emission.phase == "tap" and emission.key_code == key_code then count = count + 1 end
		end
		return count
	end

	local CAPS = { caps_lock = { tap = "return", hold = "ctrl" } }

	helpers.describe("Generator tap minimum (tap-min-macos)", function()
		helpers.it("a release sooner than the tap minimum types no tap and holds nothing (tap-min-macos)", function()
			local engine = engine_for(build(CAPS))
			press(engine, "caps_lock", 20)
			helpers.assert_eq(taps(engine, "return_or_enter"), 0, "a 20 ms bounce is not a tap")
			helpers.assert_nil(next(engine:pressed()), "the hold taken at key-down is released")
			engine:clear()
			press(engine, "caps_lock", TAP_MIN_MS - 1)
			helpers.assert_eq(taps(engine, "return_or_enter"), 0, "one millisecond short of the minimum is not a tap")
		end)

		helpers.it("a release at or past the tap minimum types the tap once (tap-min-macos)", function()
			local engine = engine_for(build(CAPS))
			press(engine, "caps_lock", TAP_MIN_MS)
			helpers.assert_eq(taps(engine, "return_or_enter"), 1, "a release at the minimum is a tap")
			engine:clear()
			press(engine, "caps_lock", 150)
			helpers.assert_eq(taps(engine, "return_or_enter"), 1, "a quick tap past the minimum is a tap")
			engine:clear()
			press(engine, "caps_lock", 20)
			helpers.assert_eq(taps(engine, "return_or_enter"), 0, "the next bounce starts from a cleared minimum")
		end)

		helpers.it("a pair's release-judged tap respects the minimum (tap-min-macos)", function()
			local engine = engine_for(build({}, { esc_tab = { combo = "none", tap = "return", hold = "cmd" } }))
			engine:down("escape")
			engine:advance(300)
			engine:clear()
			press(engine, "tab", 20)
			helpers.assert_eq(taps(engine, "return_or_enter"), 0, "a 20 ms second key is a bounce")
			engine:clear()
			press(engine, "tab", TAP_MIN_MS + 10)
			helpers.assert_eq(taps(engine, "return_or_enter"), 1, "a second key held past the minimum taps the pair")
		end)

		helpers.it("a rollover key keeps no minimum, as the Linux roll keys (tap-min-macos)", function()
			local engine = engine_for(build({ spacebar = { tap = "none", hold = "shift" } }))
			press(engine, "spacebar", 20)
			helpers.assert_eq(taps(engine, "spacebar"), 1, "the rollover key's quick release types its native key")
		end)

		helpers.it("the minimum's variable is scoped to the lease generation (tap-min-macos)", function()
			local scoped = "ergopti_ke_held_caps_lock_tap_min_" .. TOKEN
			local gated, timed = 0, 0
			for _, rule in ipairs(build(CAPS)) do
				for _, manipulator in ipairs(rule.manipulators) do
					if manipulator.from and manipulator.from.key_code == "caps_lock" and manipulator.to_if_alone then
						for _, event in ipairs(manipulator.to_if_alone) do
							for _, condition in ipairs(event.conditions or {}) do
								if condition.name == scoped and condition.value == 1 then gated = gated + 1 end
								helpers.assert_true(condition.name ~= "ke_held_caps_lock_tap_min", "no bare runtime name")
							end
						end
						helpers.assert_eq(manipulator.parameters["basic.to_delayed_action_delay_milliseconds"], TAP_MIN_MS,
							"the delayed action is timed by the registry's minimum")
						timed = timed + 1
					end
				end
			end
			helpers.assert_true(timed > 0, "the caps_lock tap manipulator is generated")
			helpers.assert_true(gated >= timed, "every tap manipulator gates its tap on the scoped variable")
		end)
	end)

	--- Whether the emissions armed the one-shot Shift (its tagged F20).
	local function armed(engine)
		for _, emission in ipairs(engine:emissions()) do
			if emission.key_code == "key_90" and emission.flags.left_control and emission.flags.left_option then
				return true
			end
		end
		return false
	end

	-- rctrl.ahk 7.3 (the Windows RCtrl, macOS's right_option, tapping the
	-- one-shot Shift with no hold): a quick release arms the one-shot; a long
	-- press holds Shift past the threshold and arms nothing. The generator sent
	-- the tap at key_down, as for any key with no hold, so even a long press
	-- armed it and nothing held Shift (one-shot-no-hold-macos).
	helpers.describe("right_option's one-shot Shift with no hold (one-shot-no-hold-macos)", function()
		local rules = build({ right_option = { tap = "sticky_shift", hold = "none" } })
		local function timeout(engine)
			local manipulator = engine:down("right_option")
			return manipulator and manipulator.parameters and manipulator.parameters[TIMEOUT_PARAMETER]
		end

		helpers.it("arms on a quick release, not at key-down (one-shot-no-hold-macos)", function()
			local engine = engine_for(rules)
			engine:down("right_option")
			helpers.assert_true(not armed(engine), "nothing is armed at key-down")
			engine:advance(TAP_MIN_MS + 50)
			engine:up("right_option", true)
			helpers.assert_true(armed(engine), "the quick release arms the one-shot")
			helpers.assert_nil(next(engine:pressed()), "and holds nothing")
		end)

		helpers.it("holds Shift for a long press and arms nothing (one-shot-no-hold-macos)", function()
			local engine = engine_for(rules)
			local limit = timeout(engine)
			helpers.assert_true(type(limit) == "number" and limit > TAP_MIN_MS, "the key has a tap threshold")
			engine:advance(limit + 50)
			helpers.assert_true(engine:pressed().left_shift == true, "past the threshold Shift is held")
			engine:up("right_option", false)
			helpers.assert_true(not armed(engine), "a long press arms nothing")
			helpers.assert_nil(next(engine:pressed()), "and its release lets Shift go")
		end)

		helpers.it("keeps the tap minimum and the shift-hold variant (one-shot-no-hold-macos)", function()
			local engine = engine_for(rules)
			engine:down("right_option")
			engine:advance(20)
			engine:up("right_option", true)
			helpers.assert_true(not armed(engine), "a 20 ms bounce arms nothing")
			engine = engine_for(build({ right_option = { tap = "sticky_shift", hold = "shift" } }))
			engine:down("right_option")
			engine:advance(150)
			engine:up("right_option", true)
			helpers.assert_true(armed(engine), "the preset's shift hold still taps the one-shot")
		end)
	end)
end)
