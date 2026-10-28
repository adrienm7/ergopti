--- tests/meta/corpus/test_corpus_tap_hold_decisions.lua

--- ==============================================================================
--- MODULE: Tap-Hold Decision Corpus Replay (Hammerspoon)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/tap_hold/decision_vectors.json through what
--- decides a tap or a hold on macOS: the real generator builds the Karabiner
--- rules of each vector's bindings from the shipped catalogues, the Karabiner
--- v16 model of tests/support/karabiner_model.lua turns the timed key stream
--- into output events, and a one-shot Shift tag it posts arms the real native
--- adapter (adapters/one_shot_shift), which then decides what the next letter
--- types. The output is read as the keystrokes an application receives.
---
--- The corpus speaks the shared vocabulary ([tap_hold.keys.*] taps and
--- holds, [tap_hold.catalog] keys); the two tables below translate it to the
--- action ids of platform/remap/data/actions.json, and an unknown name fails.
--- ==============================================================================

local helpers        = require("tests.helpers")
local KarabinerModel = require("tests.support.karabiner_model")
local SourceFile     = require("tests.support.source_file")
local Catalog        = require("tap_hold.key_catalog")
local ControlSignals = require("keymap.control_signals")
local Contract       = require("test.tap_hold_decision_contract")

local TOKEN    = "0123456789abcdef0123456789abcdef"
local DATA_DIR = helpers.driver_root() .. "platform/remap/data/"
local TIMEOUT_PARAMETER = "basic.to_if_alone_timeout_milliseconds"

local defaults = require("toml_codec").decode(SourceFile.read(helpers.shared("tap_hold/defaults.toml")))
local corpus = assert(require("json").decode(SourceFile.read(helpers.shared("tests/corpus/tap_hold/decision_vectors.json"))))
local one_shot_data = assert(require("json").decode(SourceFile.read(helpers.shared("tap_hold/one_shot_shift.json"))))

-- The corpus taps, by the actions.json id that types them; nil taps the key itself.
local TAP_ACTION_OF = {
	enter = "return", escape = "escape", tab = "tab", backspace = "backspace", space = "space",
	one_shot_shift = "sticky_shift",
}
-- The corpus holds, by the actions.json id that holds them.
local HOLD_ACTION_OF = { ctrl = "ctrl", shift = "shift", alt = "alt", win = "cmd" }

-- The hold-picker name and the side-specific name of each Karabiner modifier flag.
local MODIFIER_OF_FLAG = {
	left_control = "ctrl", right_control = "ctrl", left_shift = "shift", right_shift = "shift",
	left_option = "alt", right_option = "alt", left_command = "win", right_command = "win",
}
local SIDED_OF_FLAG = {
	left_control = "left_ctrl", right_control = "right_ctrl", left_shift = "left_shift",
	right_shift = "right_shift", left_option = "left_alt", right_option = "right_alt",
	left_command = "left_win", right_command = "right_win",
}

-- The ordinary keys the corpus strikes: Karabiner key code and Quartz key code (ANSI).
local LETTERS = { a = { key_code = "a", quartz = 0 }, j = { key_code = "j", quartz = 38 } }

-- Quartz flag bits of the one-shot adapter's event double, and the text each letter types.
local SHIFT_BIT, CMD_BIT, CTRL_BIT, ALT_BIT = 2, 4, 8, 16
local TEXT_OF_QUARTZ = { [0] = { "a", "A" }, [38] = { "j", "J" } }

--- A Quartz key event double the one-shot adapter reads and rewrites.
--- @param code number Quartz key code.
--- @param raw number Raw flag bits.
--- @return table event
local function quartz_event(code, raw)
	local unicode = nil
	return {
		getKeyCode = function() return code end,
		getFlags = function()
			return { cmd = (raw & CMD_BIT) ~= 0, ctrl = (raw & CTRL_BIT) ~= 0, alt = (raw & ALT_BIT) ~= 0 }
		end,
		rawFlags = function(_, value) if value ~= nil then raw = value end; return raw end,
		getCharacters = function()
			if unicode ~= nil then return unicode end
			local choices = assert(TEXT_OF_QUARTZ[code], "no text for Quartz key " .. tostring(code))
			return choices[(raw & SHIFT_BIT) ~= 0 and 2 or 1]
		end,
		setUnicodeString = function(_, value) unicode = value end,
	}
end

helpers.with_fresh_modules({
	"adapters.file_system",
	"infra.config_paths",
	"infra.keycodes",
	"infra.logger",
	"infra.toml.codec",
	"platform.remap.config",
	"platform.remap.generator",
	"modules.keymap.layout_registry",
	"toml_codec",
	"adapters.one_shot_shift",
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
		F19_LAYER_NAV_EXITED    = 80,
	}
	-- The catalogues read here are JSON and the shared defaults use the
	-- pure-Lua reader; the native TOML codec is absent from the headless runner.
	local toml_stub = { encode = function() return "" end, decode = function() return {} end }
	package.loaded["toml_codec"] = toml_stub
	package.loaded["infra.toml.codec"] = toml_stub
	local file_cache = {}
	local function read_once(path)
		if file_cache[path] == nil then file_cache[path] = SourceFile.read(path) end
		return file_cache[path]
	end
	package.loaded["adapters.file_system"] = {
		read = read_once,
		read_with_status = function(path) return read_once(path), "ok" end,
	}
	package.loaded["modules.keymap.layout_registry"] =
		require("tests.support.active_layout_registry_fixture").new("ergopti", "iso")

	local Config    = helpers.load_with_stubs("platform.remap.config")
	local Generator = helpers.load_with_stubs("platform.remap.generator")
	local OneShot   = require("adapters.one_shot_shift")
	local Defaults  = require("platform.remap.defaults")

	local actions = assert(Config.load_available_actions(DATA_DIR .. "actions.json"))
	local keys    = assert(Config.load_tap_hold_keys(DATA_DIR .. "tap_hold_keys.json"))
	local combos  = assert(Config.load_mod_combos(DATA_DIR .. "mod_combos.json"))
	local non_canonical = Config.compute_non_canonical_combos(combos)

	-- Catalogue id -> this driver's key id and Karabiner key code; key code -> catalogue id.
	local key_code_of_id = {}
	for _, key_def in ipairs(keys) do key_code_of_id[key_def.id] = key_def.from.key_code end
	local ID_OF_KEY, KEY_CODE_OF_KEY, KEY_OF_KEY_CODE = {}, {}, {}
	for _, entry in ipairs(Catalog.for_platform(defaults, "hs")) do
		local key_code = assert(key_code_of_id[entry.id], "tap_hold_keys.json has no key '" .. entry.id .. "'")
		ID_OF_KEY[entry.key] = entry.id
		KEY_CODE_OF_KEY[entry.key] = key_code
		if not KarabinerModel.MODIFIER_KEY_CODES[key_code] then KEY_OF_KEY_CODE[key_code] = entry.key end
	end
	local QUARTZ_OF_KEY_CODE = {}
	for key, letter in pairs(LETTERS) do
		KEY_CODE_OF_KEY[key] = letter.key_code
		KEY_OF_KEY_CODE[letter.key_code] = key
		QUARTZ_OF_KEY_CODE[letter.key_code] = letter.quartz
	end
	local sentinel = "key_90"

	--- Builds the rules of one vector: every key and combination off, then its bindings.
	--- @param vector table
	--- @return table rules
	local function build(vector)
		local state = Config.build_default_state(keys, combos)
		state.tap_holds_enabled = true
		for key, binding in pairs(vector.bindings) do
			local id = assert(ID_OF_KEY[key], vector.id .. ": '" .. key .. "' is no macOS tap-hold key")
			local tap = binding.tap == nil and "none"
				or assert(TAP_ACTION_OF[binding.tap], vector.id .. ": no macOS action types '" .. tostring(binding.tap) .. "'")
			local hold = assert(HOLD_ACTION_OF[binding.hold], vector.id .. ": no macOS action holds '" .. binding.hold .. "'")
			state.tap_hold_config[id] = { tap = tap, hold = hold, timeout_ms = binding.threshold_ms }
		end
		local config, err = Generator.build_karabiner_json(state, actions, keys, combos, non_canonical, DATA_DIR, TOKEN)
		assert(config, vector.id .. ": generation failed: " .. tostring(err))
		return config.profiles[1].complex_modifications.rules
	end

	--- Replays one vector and reads what applications receive.
	--- @param vector table
	--- @return table { strokes, hold_presses }
	local function replay(vector)
		local rules = build(vector)
		local engine = KarabinerModel.new(rules, { variables = { [Generator.mode_variable_name(TOKEN)] = 1 } })
		local adapter = OneShot.new({
			data = one_shot_data,
			magic = function() return "★" end,
			now = function() return engine.now / 1000 end,
			event = { rawFlagMasks = { shift = SHIFT_BIT } },
			translate = function(code, raw) return quartz_event(code, raw):getCharacters(false) end,
			is_repeat = function() return false end,
			emit = function() error(vector.id .. ": the corpus letters need no text replacement") end,
		})
		local first_bound = nil
		for _, event in ipairs(vector.events) do
			if event[1] == "down" and vector.bindings[event[2]] then first_bound = event[2]; break end
		end
		local strokes, hold_presses, limits, down_at = {}, {}, {}, {}
		local read_upto = 0

		--- Reads the emissions posted since the last call.
		local function read_emissions()
			local emissions = engine:emissions()
			for index = read_upto + 1, #emissions do
				local emission = emissions[index]
				local key_code = emission.key_code
				if key_code == sentinel then
					local quartz = {}
					for flag in pairs(emission.flags) do
						local role = MODIFIER_OF_FLAG[flag]
						if role == "win" then quartz.cmd = true elseif role then quartz[role] = true end
					end
					if ControlSignals.decode(quartz) == "one_shot_shift" then
						adapter.arm(Defaults.sticky_timeout_ms / 1000)
					end
				elseif key_code ~= nil and emission.phase ~= "lock" and not KarabinerModel.MODIFIER_KEY_CODES[key_code] then
					local held, raw = {}, 0
					for flag in pairs(emission.flags) do
						local role = MODIFIER_OF_FLAG[flag]
						if role then held[role] = true end
						if role == "ctrl" then raw = raw | CTRL_BIT end
						if role == "alt" then raw = raw | ALT_BIT end
						if role == "win" then raw = raw | CMD_BIT end
						if role == "shift" then raw = raw | SHIFT_BIT end
					end
					local quartz = QUARTZ_OF_KEY_CODE[key_code]
					if quartz ~= nil and emission.phase == "down" then
						local typed = quartz_event(quartz, raw)
						adapter.key_down(typed, quartz)
						adapter.finish(true)
						if (typed:rawFlags() & SHIFT_BIT) ~= 0 then held.shift = true end
					end
					strokes[#strokes + 1] = {
						key = assert(KEY_OF_KEY_CODE[key_code], vector.id .. ": unnamed key " .. tostring(key_code)),
						mods = held,
					}
				end
			end
			read_upto = #emissions
		end

		for _, event in ipairs(vector.events) do
			local key = event[2]
			local key_code = assert(KEY_CODE_OF_KEY[key], vector.id .. ": unknown key '" .. key .. "'")
			engine:advance(event[3] - engine.now)
			read_emissions()
			if event[1] == "down" then
				local before = engine:pressed()
				local manipulator = engine:down(key_code)
				down_at[key_code] = engine.now
				-- Karabiner reads the tap timeout of the manipulator that took the key;
				-- a key no manipulator took, or one without a tap, has none to keep.
				if manipulator and manipulator.to_if_alone then
					limits[key_code] = assert(manipulator.parameters and manipulator.parameters[TIMEOUT_PARAMETER],
						vector.id .. ": a tap manipulator without its timeout")
				else
					limits[key_code] = math.huge
				end
				if key == first_bound and #hold_presses == 0 then
					local after = engine:pressed()
					for _, flag in ipairs(KarabinerModel.FLAGS) do
						if after[flag] and not before[flag] and SIDED_OF_FLAG[flag] then
							hold_presses[#hold_presses + 1] = SIDED_OF_FLAG[flag]
						end
					end
				end
			else
				engine:up(key_code, engine.now - down_at[key_code] < limits[key_code])
				local quartz = QUARTZ_OF_KEY_CODE[key_code]
				if quartz ~= nil then adapter.key_up(quartz_event(quartz, 0), quartz) end
			end
			read_emissions()
		end
		return { strokes = strokes, hold_presses = hold_presses }
	end

	Contract.run(helpers, "macos", corpus, defaults.tap_hold.hold_picker, replay)
end)
