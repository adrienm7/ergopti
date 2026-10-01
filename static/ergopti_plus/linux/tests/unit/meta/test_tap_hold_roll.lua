--- tests/unit/meta/test_tap_hold_roll.lua

--- ==============================================================================
--- MODULE: A Typing Key Rolled Over The Next One Is A Tap
--- DESCRIPTION:
--- With Shift as the hold of Space, fast typing turned « word, Space, letter »
--- into the letter in capitals and no space: the hold was taken as soon as
--- Space went down, so a letter struck before Space came up was shifted, and
--- the other key cancelled the tap (« fonctionnerA ussi », 2026-10-01). A
--- typing key that keeps its own key on a tap is now decided by the order of
--- the releases. The real hook, manager and writer run on the shipped defaults,
--- fed timestamped key streams; each case reads what the desktop receives.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")
local EV_KEY = 1
local DOWN, UP, REPEAT = 1, 0, 2
local SPACE, LSHIFT, LCTRL, CAPS, ENTER = 57, 42, 29, 58, 28
local KEY_A, KEY_J = 30, 36

--- Runs body(drive) on a hook, a manager and the recommended layer, with the
--- user's tap_hold.toml holding `user_text`. drive(events) feeds
--- { code, value, at_ms } events and returns what the desktop receives.
local function with_session(user_text, body)
	local Hook = helpers.load_module("adapters.keyboard_hook")
	local Manager = helpers.load_module("platform.remap.tap_hold_manager")
	local dir = os.tmpname()
	os.remove(dir)
	local made = os.execute('mkdir "' .. dir .. '"')
	assert(made == true or made == 0, "the isolated configuration folder must exist")
	local path = dir .. "/tap_hold.toml"
	require("tests.support.nav_layer_fixture").write(dir)
	local fh = assert(io.open(path, "w"))
	fh:write(user_text)
	fh:close()
	local ok, err = pcall(function()
		Manager.init({
			keyboard_hook = Hook,
			execute_action = function() end,
			action_names = function() return {} end,
			on_text_injected = function() end,
			defaults_path = DEFAULTS,
			user_path = path,
		})
		body(function(events)
			local emitted, stream = {}, {}
			for index, e in ipairs(events) do
				stream[index] = { type = EV_KEY, code = e[1], value = e[2], at_ms = e[3] }
			end
			Hook._test_drive(stream, {
				onEmitRaw = function(code, value) emitted[#emitted + 1] = code .. ":" .. value; return true end,
				onChar = function() end,
			}, true)
			local down = {}
			for _, pair in ipairs(emitted) do
				local code, value = pair:match("^(%d+):(%d+)$")
				if value == "1" then down[code] = true elseif value == "0" then down[code] = nil end
			end
			helpers.assert_nil(next(down), "no key may be left down: " .. table.concat(emitted, " "))
			return table.concat(emitted, " ")
		end)
	end)
	Manager._reset_for_test()
	os.remove(path)
	os.remove(dir .. "/layers.toml")
	os.execute('rmdir "' .. dir .. '"')
	if not ok then error(err, 0) end
end

-- Space as the maintainer set it: its own key on a tap, Shift on a hold.
local SPACE_SHIFT = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.space]\nhold_modifier = "shift"\n'
local SPACE_LAYER = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.space]\nhold_layer = "nav"\n'

helpers.describe("tap-hold roll: a typing key is decided by the order of the releases", function()

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) Space rolled over a letter types the space, then the letter", function()
		with_session(SPACE_SHIFT, function(drive)
			helpers.assert_eq(drive({ { SPACE, DOWN, 1000 }, { KEY_A, DOWN, 1060 }, { SPACE, UP, 1090 }, { KEY_A, UP, 1130 } }),
				"57:1 57:0 30:1 30:0", "the letter was once shifted and the space lost")
		end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) a letter struck and let go under Space is held", function()
		with_session(SPACE_SHIFT, function(drive)
			helpers.assert_eq(drive({ { SPACE, DOWN, 1000 }, { KEY_A, DOWN, 1060 }, { KEY_A, UP, 1120 }, { SPACE, UP, 1180 } }),
				"42:1 30:1 30:0 42:0", "the hold needs no wait when the letter comes up first")
		end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) Space held past its threshold is the hold for every key after it", function()
		with_session(SPACE_SHIFT, function(drive)
			helpers.assert_eq(drive({ { SPACE, DOWN, 1000 }, { KEY_A, DOWN, 1300 }, { SPACE, UP, 1330 }, { KEY_A, UP, 1360 } }),
				"42:1 30:1 42:0 30:0", "past the threshold a roll is a chord")
			helpers.assert_eq(drive({ { SPACE, DOWN, 5000 }, { SPACE, UP, 5500 } }), "42:1 42:0",
				"a long lone press types no space")
			helpers.assert_eq(drive({ { SPACE, DOWN, 9000 }, { KEY_A, DOWN, 9100 }, { KEY_A, REPEAT, 9400 },
				{ KEY_A, UP, 9450 }, { SPACE, UP, 9500 } }), "42:1 30:1 30:2 30:0 42:0",
				"a letter still down at the threshold is typed under the hold, and its repeat follows")
		end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) a lone tap types the space, however short", function()
		with_session(SPACE_SHIFT, function(drive)
			helpers.assert_eq(drive({ { SPACE, DOWN, 1000 }, { SPACE, UP, 1080 } }), "57:1 57:0")
			helpers.assert_eq(drive({ { SPACE, DOWN, 3000 }, { SPACE, UP, 3020 } }), "57:1 57:0",
				"a typist's 20 ms press is a space, not a bounce")
		end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) a second key struck before either comes up is typing", function()
		with_session(SPACE_SHIFT, function(drive)
			helpers.assert_eq(drive({ { SPACE, DOWN, 1000 }, { KEY_A, DOWN, 1040 }, { KEY_J, DOWN, 1070 },
				{ KEY_A, UP, 1090 }, { SPACE, UP, 1100 }, { KEY_J, UP, 1130 } }),
				"57:1 57:0 30:1 36:1 30:0 36:0", "the space, then both letters in the order they were struck")
		end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) the release of the letter before does not cancel the space", function()
		with_session(SPACE_SHIFT, function(drive)
			helpers.assert_eq(drive({ { KEY_A, DOWN, 1000 }, { SPACE, DOWN, 1050 }, { KEY_A, UP, 1080 }, { SPACE, UP, 1120 } }),
				"30:1 30:0 57:1 57:0", "a letter still down when Space is struck is the word being typed")
		end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) the layer on a hold follows the same order", function()
		with_session(SPACE_LAYER, function(drive)
			helpers.assert_eq(drive({ { SPACE, DOWN, 1000 }, { KEY_J, DOWN, 1060 }, { SPACE, UP, 1090 }, { KEY_J, UP, 1130 } }),
				"57:1 57:0 36:1 36:0", "a roll types the space and the letter itself")
			local nested = drive({ { SPACE, DOWN, 3000 }, { KEY_J, DOWN, 3060 }, { KEY_J, UP, 3120 }, { SPACE, UP, 3180 } })
			helpers.assert_true(nested ~= "" and not nested:find("36:1", 1, true) and not nested:find("57:1", 1, true),
				"a letter let go under Space is the layer's key, got '" .. nested .. "'")
		end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) Enter with a hold of its own follows the same order", function()
		with_session('[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.enter]\nhold_modifier = "ctrl"\n', function(drive)
			helpers.assert_eq(drive({ { ENTER, DOWN, 1000 }, { KEY_A, DOWN, 1060 }, { ENTER, UP, 1090 }, { KEY_A, UP, 1130 } }),
				"28:1 28:0 30:1 30:0")
			helpers.assert_eq(drive({ { ENTER, DOWN, 3000 }, { KEY_A, DOWN, 3060 }, { KEY_A, UP, 3120 }, { ENTER, UP, 3180 } }),
				"29:1 30:1 30:0 29:0", "a quick chord is still a chord: no Enter is typed")
		end)
	end)

	-- The rule is for keys struck in the flow of text. A key that is not one, or
	-- whose tap is an action, keeps the hold it takes at key-down: its chords
	-- and clicks must not wait.
	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) a key that is not a typing key keeps its hold from key-down", function()
		with_session('[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.caps_lock]\ntap_action = "enter"\nhold_modifier = "ctrl"\n',
			function(drive)
				helpers.assert_eq(drive({ { CAPS, DOWN, 1000 }, { KEY_A, DOWN, 1060 }, { CAPS, UP, 1090 }, { KEY_A, UP, 1130 } }),
					"29:1 30:1 29:0 30:0", "CapsLock held as Ctrl is a Ctrl from its key-down")
			end)
		with_session('[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.space]\ntap_action = "enter"\nhold_modifier = "shift"\n',
			function(drive)
				helpers.assert_eq(drive({ { SPACE, DOWN, 1000 }, { KEY_A, DOWN, 1060 }, { KEY_A, UP, 1090 }, { SPACE, UP, 1130 } }),
					"42:1 30:1 30:0 42:0", "Space tapping another key than itself is not typed text")
			end)
	end)

	helpers.it("(tap-hold-roll-is-a-tap-2026-10-01) the typing keys are the shared list", function()
		local loaded = require("platform.remap.tap_hold_loader").load(DEFAULTS, nil)
		table.sort(loaded.roll_keys)
		helpers.assert_eq(table.concat(loaded.roll_keys, ","), "backspace,delete,enter,escape,space,tab")
		helpers.assert_true(LSHIFT == 42 and LCTRL == 29, "the modifier codes the streams above read")
	end)

end)
