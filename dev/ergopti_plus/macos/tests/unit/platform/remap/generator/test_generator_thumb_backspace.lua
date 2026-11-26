--- tests/unit/platform/remap/generator/test_generator_thumb_backspace.lua

--- ==============================================================================
--- MODULE: Generator Thumb Backspace Under Held Modifiers
--- DESCRIPTION:
--- Left Command tapping Backspace deletes what Windows' BackSpaceLogic and the
--- Linux engine delete under the keys held (maintainer decision THD-4 of
--- 2026-11-21): Forward Delete under Shift or the one-shot right Option, a word
--- back (Option+Backspace) under Control, a word forward (Option+Forward
--- Delete) under Control and Shift. The real generator builds the rules and the
--- Karabiner v16 model replays the shared vectors of
--- _shared/tests/corpus/tap_hold/thumb_backspace_vectors.json. Before it the
--- macOS rules sent a bare Backspace under every modifier.
--- ==============================================================================

local helpers        = require("tests.helpers")
local KarabinerModel = require("tests.support.karabiner_model")
local SourceFile     = require("tests.support.source_file")

local TOKEN    = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"
local TIMEOUT_PARAMETER = "basic.to_if_alone_timeout_milliseconds"

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

	local Config    = helpers.load_with_stubs("platform.remap.config")
	local Generator = helpers.load_with_stubs("platform.remap.generator")
	local corpus = assert(require("core.text.engine.json").decode(
		SourceFile.read(helpers.shared("tests/corpus/tap_hold/thumb_backspace_vectors.json"))))

	local actions = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
	local keys    = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
	local combos  = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
	local non_canonical = Config.compute_non_canonical_combos(combos)

	-- The corpus' held keys as macOS keys; the right-hand key's binding follows
	-- right_ctrl_tap (the one-shot Shift holding Shift, as shipped, or a Ctrl).
	local HELD_KEY = { shift = "left_shift", left_ctrl = "left_control", right_ctrl = "right_option" }
	local RIGHT_KEY = {
		one_shot_shift = { tap = "sticky_shift", hold = "shift" },
		none           = { tap = "none", hold = "ctrl" },
	}

	--- Builds the deployed rules for one vector.
	--- @param right_ctrl_tap string The vector's right_ctrl_tap.
	--- @param hold string Left Command's hold action.
	--- @return table rules
	local function build(right_ctrl_tap, hold)
		local state = Config.build_default_state(keys, combos)
		state.tap_holds_enabled = true
		state.lone_modifier_tap_max_ms = 0
		state.tap_hold_config.left_command = { tap = "backspace", hold = hold }
		state.tap_hold_config.left_shift = { tap = "none", hold = "none" }
		state.tap_hold_config.left_control = { tap = "none", hold = "none" }
		state.tap_hold_config.right_option = assert(RIGHT_KEY[right_ctrl_tap], right_ctrl_tap)
		local config, err = Generator.build_karabiner_json(state, actions, keys, combos, non_canonical, DATA_DIR, TOKEN)
		assert(config, "generation failed: " .. tostring(err))
		return config.profiles[1].complex_modifications.rules
	end

	--- Whether an emitted event, or the flags it is read with, carry a modifier.
	--- @param emission table
	--- @param modifier string "option", "control" or "shift".
	--- @return boolean
	local function has(emission, modifier)
		for _, name in ipairs(emission.event.modifiers or {}) do if name == modifier then return true end end
		return emission.flags["left_" .. modifier] == true or emission.flags["right_" .. modifier] == true
	end

	--- What the tap deleted, in the corpus' words.
	--- @param engine table
	--- @return string|nil deletion
	--- @return table|nil emission
	local function deletion(engine)
		for _, emission in ipairs(engine:emissions()) do
			local key = emission.key_code
			if (emission.phase == "tap" or emission.phase == "down")
				and (key == "delete_or_backspace" or key == "delete_forward") then
				return (has(emission, "option") and "word" or "char")
					.. (key == "delete_forward" and "_forward" or "_back"), emission
			end
		end
		return nil
	end

	helpers.describe("Generator thumb Backspace under held modifiers (thumb-backspace-vectors)", function()
		for _, hold in ipairs({ "layer", "cmd", "none" }) do
			helpers.it("left Command (hold " .. hold .. ") replays the shared vectors (thumb-backspace-vectors)", function()
				helpers.assert_eq(#corpus.vectors, 8, "every thumb Backspace vector is replayed")
				for _, vector in ipairs(corpus.vectors) do
					local engine = KarabinerModel.new(build(vector.right_ctrl_tap, hold),
						{ variables = { [Generator.mode_variable_name(TOKEN)] = 1 } })
					for _, key in ipairs(vector.held) do engine:down(assert(HELD_KEY[key], key)) end
					engine:clear()
					local manipulator = engine:down("left_command")
					local limit = manipulator and manipulator.parameters
						and manipulator.parameters[TIMEOUT_PARAMETER] or math.huge
					engine:advance(KarabinerModel.TAP_MS)
					local got, emission = deletion(engine)
					if got == nil then
						engine:up("left_command", KarabinerModel.TAP_MS < limit)
						got, emission = deletion(engine)
					end
					helpers.assert_eq(got, vector.expected, vector.id .. " (hold " .. hold .. ")")
					helpers.assert_true(not has(emission, "control") and not has(emission, "shift"),
						vector.id .. ": the held Control and Shift are lifted around the deletion")
				end
			end)
		end
	end)
end)
