--- tests/unit/platform/remap/tap_hold/test_tap_hold_lone_tap_window.lua

--- ==============================================================================
--- MODULE: Lone Modifier Tap Window (Linux)
--- DESCRIPTION:
--- A tap-hold key whose hold is a modifier, pressed alone, still types its tap
--- up to tap_holds.lone_modifier_tap_max_ms: a deliberate Shift tap for Copy
--- often lasts past the 200 ms threshold and copied nothing. A chord is still
--- decided by the hold, 0 is the strict tap-hold and a typing key keeps its
--- threshold. Linux stores the window in tap_hold.toml ([tap_hold]
--- lone_modifier_tap_max_ms): the writer's value is what the loader hands the
--- engine, 0 included, and an invalid one is refused for the manifest default.
--- ==============================================================================

package.loaded["tests.support.platform.remap.tap_hold.tap_hold_engine_fixture"] = nil
local Fixture = require("tests.support.platform.remap.tap_hold.tap_hold_engine_fixture")
local helpers, Engine, DOWN, UP, SHIFT, CTRL, CAPS, KEY_A, trail =
	Fixture.helpers, Fixture.Engine, Fixture.DOWN, Fixture.UP, Fixture.SHIFT, Fixture.CTRL, Fixture.CAPS,
	Fixture.KEY_A, Fixture.trail
local Loader = require("platform.remap.tap_hold_loader")
local Manifest = require("menu.engine.manifest_reader")
local ConfigKeys = require("settings.engine.keys")

local SPACE = 57
local DEFAULTS_PATH = require("core.fs.engine.paths").shared("tap_hold/data/defaults.toml")

-- The keys of the field report, each with the shipped 200 ms threshold.
local KEYS = {
	caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 0.2 },
	left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = 0.2 },
	space = { tap_action = "", hold_modifier = "ctrl", time_activation_seconds = 0.2 },
}

--- An engine on KEYS with the given window, Space a typing key.
--- @param window_ms number
--- @return table
local function engine(window_ms)
	return Engine.new({ keys = KEYS, roll_keys = { "space" }, tap_min_ms = 50, lone_tap_max_ms = window_ms,
		one_shot_timeout_ms = 2000, key_text = Fixture.us_text, plan_text = Fixture.us_plan,
		one_shot_result = Fixture.one_shot_result })
end

--- Presses and releases one key alone, ticking first as the hook does.
--- @return table release_events, string|nil tap
local function lone_press(e, code, release_ms)
	e:tick(0)
	e:process(code, DOWN, 0)
	e:tick(release_ms)
	return e:process(code, UP, release_ms)
end

local function write_file(path, text)
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
end

--- A writer bound to the tap_hold.toml of a throwaway folder, whose
--- config.toml holds the window.
--- @return table writer, string path, table state { reloads }, string config_path
local function fresh_writer()
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local path = dir .. "/tap_hold.toml"
	local state = { reloads = 0 }
	local writer = helpers.load_module("platform.remap.tap_hold_writer")
	writer.init({
		path = path,
		reload = function() state.reloads = state.reloads + 1; return true end,
		is_tap_action = function(id) return id == "copy" end,
		canonical_hold = function(kind, id)
			return require("tap_hold.engine.hold_options").canonical(kind, id, Loader.load(DEFAULTS_PATH, nil).hold_picker)
		end,
	})
	return writer, path, state, dir .. "/config.toml"
end

--- Removes a fresh_writer() folder and the files it may hold.
local function discard(path)
	local dir = path:match("^(.*)/[^/]+$")
	for _, name in ipairs({ "tap_hold.toml", "config.toml", "config.toml.tmp" }) do os.remove(dir .. "/" .. name) end
	os.execute('rmdir "' .. dir .. '"')
end

helpers.describe("tap-hold engine: a modifier key pressed alone (lone-tap-window)", function()

	helpers.it("types CapsLock's Enter on a lone 600 ms press within a 1000 ms window (lone-tap-window)", function()
		local out = lone_press(engine(1000), CAPS, 600)
		helpers.assert_eq(trail(out), "29↑ 28↓ 28↑", "past the 200 ms threshold, alone, it is still the tap")
	end)

	helpers.it("copies on a lone 600 ms Left Shift within a 1000 ms window (lone-tap-window)", function()
		local _, tap = lone_press(engine(1000), SHIFT, 600)
		helpers.assert_eq(tap, "copy", "the field report's Shift tap for Copy")
	end)

	helpers.it("keeps a chord when a letter is struck under the key (lone-tap-window)", function()
		local e = engine(1000)
		helpers.assert_eq(trail(e:process(CAPS, DOWN, 0)), "29↓", "the hold is taken at key-down")
		helpers.assert_nil(e:process(KEY_A, DOWN, 300), "the letter passes through under Ctrl")
		e:process(KEY_A, UP, 350)
		local out, tap = e:process(CAPS, UP, 600)
		helpers.assert_eq(trail(out), "29↑", "Ctrl+A types no Enter")
		helpers.assert_nil(tap)
		local shift = engine(1000)
		shift:process(SHIFT, DOWN, 0)
		shift:process(KEY_A, DOWN, 100)
		shift:process(KEY_A, UP, 150)
		local _, copy = shift:process(SHIFT, UP, 600)
		helpers.assert_nil(copy, "Shift+A copies nothing")
	end)

	helpers.it("is a hold past the threshold when the window is 0 (lone-tap-window)", function()
		local out = lone_press(engine(0), CAPS, 600)
		helpers.assert_eq(trail(out), "29↑", "the strict tap-hold: no Enter after 200 ms")
		local _, tap = lone_press(engine(0), SHIFT, 600)
		helpers.assert_nil(tap, "the strict tap-hold: no copy after 200 ms")
	end)

	helpers.it("is a hold past the window itself (lone-tap-window)", function()
		local _, tap = lone_press(engine(1000), SHIFT, 1100)
		helpers.assert_nil(tap, "a press longer than the window is a hold")
	end)

	helpers.it("keeps a typing key on its own threshold (lone-tap-window)", function()
		local quick = lone_press(engine(1000), SPACE, 120)
		helpers.assert_true(trail(quick):find("57↓", 1, true) ~= nil, "a quick Space is a space")
		local out = lone_press(engine(1000), SPACE, 600)
		helpers.assert_nil(trail(out):find("57↓", 1, true), "a 600 ms Space is a Ctrl hold, the window aside")
		helpers.assert_true(trail(out):find(CTRL .. "↑", 1, true) ~= nil, "its Ctrl hold is released")
	end)
end)

helpers.describe("tap-hold storage: the window in config.toml (lone-tap-window)", function()

	helpers.it("loads the manifest default when config.toml sets no window (lone-tap-window)", function()
		local default = Manifest.default_for(ConfigKeys.KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS)
		helpers.assert_eq(Loader.load(DEFAULTS_PATH, nil).lone_tap_max_ms, default)
		helpers.assert_eq(Loader.LONE_TAP_DEFAULT_MS, default)
	end)

	helpers.it("round-trips the writer's value through the loader, 0 included (lone-tap-window)", function()
		local writer, path, state, config_path = fresh_writer()
		for _, ms in ipairs({ 750, 0, 1500 }) do
			helpers.assert_true(writer.set_lone_tap_max_ms(ms), "a valid window is written")
			helpers.assert_eq(Loader.load(DEFAULTS_PATH, path, config_path).lone_tap_max_ms, ms,
				"the engine runs the stored window")
		end
		helpers.assert_eq(state.reloads, 3, "each change is in force at once")
		helpers.assert_nil(io.open(path, "r"), "tap_hold.toml is not written: the window is a config.toml row")
		discard(path)
	end)

	helpers.it("refuses an invalid window in the writer and writes nothing (lone-tap-window)", function()
		local writer, path, state, config_path = fresh_writer()
		for _, bad in ipairs({ -1, 12.5, "1000", math.huge }) do
			helpers.assert_eq(writer.set_lone_tap_max_ms(bad), false, "refused: " .. tostring(bad))
		end
		for _, file in ipairs({ path, config_path }) do
			local written = io.open(file, "r")
			if written then written:close() end
			helpers.assert_nil(written, "no file is written")
		end
		helpers.assert_eq(state.reloads, 0)
		discard(path)
	end)

	helpers.it("reads an invalid stored window as the manifest default (lone-tap-window)", function()
		local config_path = os.tmpname()
		for _, stored in ipairs({ "-5", "12.5", '"1000"', "true" }) do
			write_file(config_path, "[tap_holds]\nlone_modifier_tap_max_ms = " .. stored .. "\n")
			helpers.assert_eq(Loader.load(DEFAULTS_PATH, nil, config_path).lone_tap_max_ms, Loader.LONE_TAP_DEFAULT_MS,
				"refused: " .. stored)
		end
		os.remove(config_path)
	end)

	helpers.it("never reads a window left in tap_hold.toml (lone-tap-window)", function()
		local path = os.tmpname()
		write_file(path, "[tap_hold]\nlone_modifier_tap_max_ms = 0\n")
		helpers.assert_eq(Loader.load(DEFAULTS_PATH, path).lone_tap_max_ms, Loader.LONE_TAP_DEFAULT_MS,
			"config.toml owns the window since config schema v22")
		os.remove(path)
	end)

	helpers.it("a scope render routes no window into tap_hold.toml and drops a stale one (lone-tap-window)", function()
		local writer, path = fresh_writer()
		local preset = Loader.preset_keys(DEFAULTS_PATH)
		local rows = { { section = ConfigKeys.KEY.TAP_HOLDS, key = ConfigKeys.LEAF.LONE_MODIFIER_TAP_MAX_MS, value = 1000 } }
		helpers.assert_eq((pcall(writer.render_scope, "recommended", {}, rows, preset)), false,
			"a manifest row is a config.toml row")
		local cleared = writer.render_scope("clear",
			require("core.text.engine.toml_codec").decode("[tap_hold]\nlone_modifier_tap_max_ms = 0\n"), {}, preset)
		local decoded = require("core.text.engine.toml_codec").decode(cleared)
		helpers.assert_nil(decoded.tap_hold and decoded.tap_hold.lone_modifier_tap_max_ms)
		discard(path)
	end)
end)

helpers.describe("tap-hold menu choices: the manifest's one list (lone-tap-window)", function()

	-- The three menus used to hold their own copy of the list (duplicate-constant
	-- ratchet); they read the feature's preset_values now.
	helpers.it("offers the feature's preset_values, Off first, and refuses a feature without them", function()
		local LoneTap = require("tap_hold.engine.lone_tap")
		local feature = Manifest.find_entry_by_path(ConfigKeys.KEY.TAP_HOLDS_LONE_MODIFIER_TAP_MAX_MS)
		helpers.assert_type(feature.preset_values, "table", "the generated manifest carries the presets")
		local choices = LoneTap.choices(feature)
		helpers.assert_eq(choices, feature.preset_values)
		helpers.assert_true(not rawequal(choices, feature.preset_values), "the menu gets a copy")
		helpers.assert_eq(choices[1], 0, "Off, the strict tap-hold, comes first")
		local default_offered = false
		for _, ms in ipairs(choices) do default_offered = default_offered or ms == Loader.LONE_TAP_DEFAULT_MS end
		helpers.assert_true(default_offered, "the default is one of the choices")
		helpers.assert_eq((pcall(LoneTap.choices, { type = "number" })), false, "no presets, no menu")
		helpers.assert_eq((pcall(LoneTap.choices, { preset_values = { 0, -5 } })), false, "a negative window is refused")
	end)
end)
