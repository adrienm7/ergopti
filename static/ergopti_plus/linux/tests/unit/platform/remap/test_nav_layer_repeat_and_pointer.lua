--- tests/unit/platform/remap/test_nav_layer_repeat_and_pointer.lua

--- ==============================================================================
--- MODULE: Navigation Layer Repeat Count And Mouse Buttons
--- DESCRIPTION:
--- The Linux layer follows Windows, the most complete driver (maintainer
--- decision of 2026-11-06): repeat_count:<N> sets how many times the next
--- repeatable action sends its last chord, any send and leaving the layer reset
--- it, and a mouse button is a layer source the hook hands to the engine.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")

local UP, DOWN, REPEAT = 0, 1, 2
local ALT, KEY_J, KEY_K, KEY_M, KEY_3 = 56, 36, 37, 50, 4
local CTRL, ARROW_UP, HOME = 29, 103, 102
local BTN_MIDDLE, ESCAPE = 274, 1

local function engine(layer)
	local instance = Engine.new({
		keys = { left_alt = { hold_layer = "nav", tap_action = "none", time_activation_seconds = 0.2 } },
		tap_min_ms = 50, lone_tap_max_ms = 0, one_shot_timeout_ms = 2000, nav_layer = layer,
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

local function layer()
	return {
		[KEY_3] = { repeat_count = 3 },
		[KEY_K] = { chords = { chord({}, ARROW_UP) }, counted = true },
		[KEY_J] = { chords = { chord({ CTRL }, HOME) } },
		[KEY_M] = { mods = {}, keys = {} },
		[BTN_MIDDLE] = { chords = { chord({}, ESCAPE) }, counted = true },
	}
end

helpers.describe("navigation layer repeat count (layer-repeat-count-linux)", function()
	helpers.it("(layer-repeat-count-linux) sends a repeatable action's last chord the count times", function()
		local instance = engine(layer())
		helpers.assert_eq(trail(instance:process(KEY_3, DOWN, 10)), "", "the count key sends nothing")
		helpers.assert_eq(trail(instance:process(KEY_3, UP, 20)), "")
		helpers.assert_eq(trail(instance:process(KEY_K, DOWN, 30)), "103:1 103:0 103:1 103:0 103:1",
			"the last chord goes three times, the third held with the key")
		helpers.assert_eq(trail(instance:process(KEY_K, REPEAT, 35)), "103:2")
		helpers.assert_eq(trail(instance:process(KEY_K, UP, 40)), "103:0")
		helpers.assert_eq(trail(instance:process(KEY_K, DOWN, 50)), "103:1", "the send reset the count to 1")
		instance:process(KEY_K, UP, 60)
	end)

	helpers.it("(layer-repeat-count-linux) a non-repeatable send spends the count, none keeps it", function()
		local instance = engine(layer())
		instance:process(KEY_3, DOWN, 10); instance:process(KEY_3, UP, 20)
		helpers.assert_eq(trail(instance:process(KEY_M, DOWN, 30)), "", "none sends nothing")
		instance:process(KEY_M, UP, 35)
		helpers.assert_eq(trail(instance:process(KEY_J, DOWN, 40)), "29:1 102:1", "a plain chord goes once")
		instance:process(KEY_J, UP, 50)
		helpers.assert_eq(trail(instance:process(KEY_K, DOWN, 60)), "103:1", "the plain chord reset the count")
		instance:process(KEY_K, UP, 70)
	end)

	helpers.it("(layer-repeat-count-linux) leaving the layer forgets an unused count", function()
		local instance = engine(layer())
		instance:process(KEY_3, DOWN, 10); instance:process(KEY_3, UP, 20)
		instance:process(ALT, UP, 400)
		instance:process(ALT, DOWN, 500)
		helpers.assert_eq(trail(instance:process(KEY_K, DOWN, 900)), "103:1", "a new hold starts at 1")
		instance:process(KEY_K, UP, 910)
	end)

	helpers.it("(layer-repeat-count-linux) a counted wheel notch sends its last chord the count times", function()
		local Input = require("platform.input.event")
		local spec = layer()
		spec[Input.wheel_layer_code("vertical", 1)] = { chords = { chord({}, ARROW_UP) }, counted = true }
		local instance = engine(spec)
		instance:process(KEY_3, DOWN, 10); instance:process(KEY_3, UP, 20)
		helpers.assert_eq(trail(instance:wheel("vertical", 1)), "103:1 103:0 103:1 103:0 103:1 103:0")
		helpers.assert_eq(trail(instance:wheel("vertical", 1)), "103:1 103:0")
	end)
end)

helpers.describe("navigation layer mouse buttons (layer-mouse-button-linux)", function()
	helpers.it("(layer-mouse-button-linux) runs a bound button and owns it until its release", function()
		local instance = engine(layer())
		helpers.assert_true(instance:pointer_bound(), "the held layer binds a button: the hook takes the mouse")
		helpers.assert_eq(trail(instance:button(BTN_MIDDLE, DOWN)), "1:1")
		instance:process(ALT, UP, 400)
		helpers.assert_true(instance:pointer_bound(), "a bound button still down keeps the mouse taken")
		helpers.assert_eq(trail(instance:button(BTN_MIDDLE, UP)), "1:0", "its release lifts the binding's key")
		helpers.assert_true(not instance:pointer_bound(), "the mouse goes back once nothing needs it")
	end)

	helpers.it("(layer-mouse-button-linux) leaves an unbound button and a button outside the layer native", function()
		local instance = engine(layer())
		helpers.assert_eq(trail(instance:button(272, DOWN)), "pass", "BTN_LEFT is not bound")
		instance:process(ALT, UP, 400)
		helpers.assert_eq(trail(instance:button(BTN_MIDDLE, DOWN)), "pass", "no layer, no binding")
		helpers.assert_eq(trail(instance:button(BTN_MIDDLE, UP)), "pass")
	end)
end)

helpers.describe("navigation layer compiler (layer-repeat-count-linux)", function()
	helpers.it("(layer-repeat-count-linux) compiles counts, counted actions and mouse buttons from layers.toml", function()
		local dir = os.tmpname()
		os.remove(dir)
		local made = os.execute('mkdir "' .. dir .. '"')
		assert(made == true or made == 0)
		local ok, err = pcall(function()
			local file = assert(io.open(dir .. "/layers.toml", "wb"))
			file:write(table.concat({ "[_meta]", "schema_version = 1", "[layers.nav.all]",
				'"Digit3" = "repeat_count:3"', '"KeyK" = "arrow_up"', '"KeyJ" = "keystroke:Home"',
				'"MouseMiddle" = "escape"', "" }, "\n"))
			file:close()
			local NavLayer = helpers.load_module("platform.remap.nav_layer")
			local shared_root = helpers.driver_root() .. "/../_shared"
			local map, observation = NavLayer.load({ shared_root = shared_root, config_dir = dir })
			helpers.assert_eq(map[KEY_3], { repeat_count = 3 })
			helpers.assert_eq(map[KEY_K], { chords = { chord({}, ARROW_UP) }, counted = true })
			helpers.assert_eq(map[KEY_J], { chords = { chord({}, HOME) } }, "a literal keystroke is not counted")
			helpers.assert_eq(map[BTN_MIDDLE], { chords = { chord({}, ESCAPE) }, counted = true })
			helpers.assert_true(observation ~= nil, "the new row fields keep the source observation")
			helpers.assert_true(NavLayer.capture_source_observation(map, observation, shared_root, dir) ~= nil)
		end)
		os.remove(dir .. "/layers.toml")
		os.execute('rmdir "' .. dir .. '"')
		if not ok then error(err, 0) end
	end)
end)
