--- tests/unit/meta/test_nav_layer_native.lua

--- ==============================================================================
--- MODULE: Native Configurable Navigation Layer
--- DESCRIPTION:
--- Runs the daemon engine with explicitly resolved layer bindings. Navigation
--- sequences may change modifiers between chords without changing tap actions.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")

local UP, DOWN, REPEAT = 0, 1, 2
local ALT, KEY_J, KEY_T = 56, 36, 20

local function engine(layer)
	local instance = Engine.new({
		keys = { left_alt = { hold_layer = "nav", tap_action = "none", time_activation_seconds = 0.2 } },
		tap_min_ms = 50, one_shot_timeout_ms = 2000, nav_layer = layer,
	})
	instance:process(ALT, DOWN, 0)
	return instance
end

local function chord(mods, key)
	return { mods = mods, keys = { key } }
end

local function trail(events)
	if events == nil then return "pass" end
	local parts = {}
	for _, event in ipairs(events) do parts[#parts + 1] = event.code .. ":" .. event.value end
	return table.concat(parts, " ")
end

helpers.describe("native navigation layer bindings", function()
	helpers.it("leaves a key native when the configured layer binds nothing", function()
		local instance = engine({})
		helpers.assert_eq(trail(instance:process(KEY_J, DOWN, 10)), "pass")
		helpers.assert_eq(trail(instance:process(KEY_J, UP, 20)), "pass")
	end)

	helpers.it("(navigation-native-case) passes every unbound letter phase without synthesizing CapsLock or Shift", function()
		local instance = engine({ [KEY_T] = chord({}, 62) })
		for _, value in ipairs({ DOWN, REPEAT, UP }) do
			helpers.assert_eq(trail(instance:process(KEY_J, value, 10)), "pass",
				"a sparse layer must preserve the native key and its existing case modifiers")
		end
		helpers.assert_eq(trail(instance:release_all()), "",
			"navigation may not retain a synthesized Shift or CapsLock for its indicator")
	end)

	helpers.it("uses the configured key instead of the old hardcoded navigation action", function()
		local instance = engine({ [KEY_T] = chord({}, 62) })
		helpers.assert_eq(trail(instance:process(KEY_T, DOWN, 10)), "62:1")
		helpers.assert_eq(trail(instance:process(KEY_T, UP, 20)), "62:0")
	end)

	helpers.it("changes modifiers between navigation chords and repeats only the final key", function()
		local instance = engine({ [KEY_J] = { chords = { chord({ 29 }, 45), chord({ 42 }, 102) } } })
		helpers.assert_eq(trail(instance:process(KEY_J, DOWN, 10)), "29:1 45:1 45:0 29:0 42:1 102:1")
		helpers.assert_eq(trail(instance:process(KEY_J, REPEAT, 20)), "102:2")
		helpers.assert_eq(trail(instance:process(KEY_J, UP, 30)), "102:0 42:0")
	end)

	helpers.it("swallows every phase of an explicit none binding", function()
		local instance = engine({ [KEY_J] = { mods = {}, keys = {} } })
		for _, value in ipairs({ DOWN, REPEAT, UP }) do
			helpers.assert_eq(trail(instance:process(KEY_J, value, 10)), "")
		end
	end)

	helpers.it("retains final-chord ownership after the layer hold is released", function()
		local instance = engine({ [KEY_J] = { chords = { chord({ 29 }, 45), chord({ 42 }, 102) } } })
		instance:process(KEY_J, DOWN, 10)
		instance:process(ALT, UP, 20)
		helpers.assert_eq(trail(instance:process(KEY_J, UP, 30)), "102:0 42:0")
		helpers.assert_eq(trail(instance:release_all()), "", "no chord key or modifier remains owned")
	end)
end)

helpers.describe("native navigation source capabilities", function()
	local Layers = require("keymap.layers")
	local Toml = require("toml_codec")
	local ctx = Layers.load_context({
		shared_root = helpers.driver_root() .. "/../_shared",
		json_decode = require("json").decode, toml_decode = Toml.decode,
		read_file = function(path)
			local file = assert(io.open(path, "rb"))
			local text = file:read("*a")
			file:close()
			return text
		end,
	})
	for _, code in ipairs({ "WheelUp", "MouseLeft" }) do
		helpers.it("refuses observed pointer input " .. code .. " with a localized reason", function()
			local text = '[_meta]\nschema_version = 1\n[layers.nav.linux]\n"' .. code .. '" = "none"\n'
			local result = Layers.load(text, "linux", ctx, Toml.decode)
			helpers.assert_eq(result.ok, false)
			helpers.assert_eq(result.errors[1].code, "unavailable_on_os")
			helpers.assert_true(type(result.errors[1].reason_key) == "string")
		end)
	end
	helpers.it("compiles numpad input and output through the physical registry", function()
		local result = Layers.load('[_meta]\nschema_version = 1\n[layers.nav.linux]\n"Numpad7" = "keystroke:ctrl+NumpadEnter"\n',
			"linux", ctx, Toml.decode)
		helpers.assert_eq(result.ok, true)
		local native = require("platform.remap.nav_layer").compile(result.layers.nav, ctx.registry)
		local instance = engine(native)
		helpers.assert_eq(trail(instance:process(71, DOWN, 10)), "29:1 96:1")
		helpers.assert_eq(trail(instance:process(71, UP, 20)), "96:0 29:0")
	end)
end)

helpers.describe("native layer brightness actions", function()
	helpers.it("emits genuine evdev brightness phases without blocking for a shell command", function()
		local NavLayer = require("platform.remap.nav_layer")
		local layer = NavLayer.compile({ KeyJ = { kind = "call", handler = "brightness_up" } },
			{ keys = { KeyJ = { kind = "key", evdev = KEY_J } } })
		local instance = engine(layer)
		helpers.assert_eq(trail(instance:process(KEY_J, DOWN, 10)), "225:1")
		helpers.assert_eq(trail(instance:process(KEY_J, REPEAT, 20)), "225:2")
		helpers.assert_eq(trail(instance:process(KEY_J, UP, 30)), "225:0")
		helpers.assert_eq(trail(instance:release_all()), "")
	end)
end)
