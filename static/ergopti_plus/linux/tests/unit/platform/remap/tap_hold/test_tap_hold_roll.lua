--- tests/unit/platform/remap/tap_hold/test_tap_hold_roll.lua

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
	local Fixture = require("tests.support.input_owner_fixture")
	Fixture.with_manager_session({ tap_hold_text = user_text, nav_fixture = true,
		action_names = { "one_shot_shift" } }, function(s)
		body(function(events)
			local before = #s.rows
			for _, event in ipairs(events) do s.edge("a", event[1], event[2], event[3]) end
			local emitted, down = {}, {}
			for index = before + 1, #s.rows do
				local code, value = s.rows[index][1], s.rows[index][2]
				emitted[#emitted + 1] = code .. ":" .. value
				if value == 1 then down[code] = true elseif value == 0 then down[code] = nil end
			end
			helpers.assert_nil(next(down), "no key may be left down: " .. table.concat(emitted, " "))
			return table.concat(emitted, " ")
		end)
	end)
end

-- Space as the maintainer set it: its own key on a tap, Shift on a hold.
local SPACE_SHIFT = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.space]\nhold_modifier = "shift"\n'
local SPACE_LAYER = '[tap_hold]\nenabled = true\ninherit_defaults = false\n[tap_hold.keys.space]\nhold_layer = "nav"\n'

helpers.describe("tap-hold roll: a typing key is decided by the order of the releases", function()
	helpers.it("retains the first origin when a second same-code source cannot be captured", function()
		local Engine = require("platform.remap.tap_hold_engine")
		local engine = Engine.new({ keys = { space = { hold_modifier = "shift" } }, roll_keys = { "space" },
			tap_min_ms = 0, lone_tap_max_ms = 0, one_shot_timeout_ms = 1000 })
		local first, calls = {}, 0
		helpers.assert_true(engine:set_roll_origin_capture(function()
			calls = calls + 1; if calls == 1 then return first end; return nil
		end, function() return true end))
		local a, b = {}, {}
		local _, _, _, initial = engine:process(SPACE, DOWN, 100, { source = "a", generation = 1, source_owner = a, source_current = true })
		helpers.assert_nil(initial)
		local rows, _, _, refused = engine:process(SPACE, DOWN, 110, { source = "b", generation = 1, source_owner = b, source_current = true })
		helpers.assert_eq(rows, {})
		helpers.assert_true(refused and refused.refused, "unowned second DOWN cannot start a journal")
		local origins = engine:take_roll_origins()
		helpers.assert_eq(#origins, 1); helpers.assert_true(rawequal(origins[1], first))
	end)

	helpers.it("does not capture or journal an ordinary unconfigured key", function()
		local Engine = require("platform.remap.tap_hold_engine")
		local engine = Engine.new({ keys = {}, roll_keys = { "space" }, tap_min_ms = 0,
			lone_tap_max_ms = 0, one_shot_timeout_ms = 1000 })
		local captures = 0
		helpers.assert_true(engine:set_roll_origin_capture(function() captures = captures + 1; return {} end,
			function() return true end))
		local _, _, _, down = engine:process(KEY_A, DOWN, 0)
		local _, _, _, up = engine:process(KEY_A, UP, 20)
		helpers.assert_nil(down); helpers.assert_nil(up)
		helpers.assert_eq(captures, 0)
	end)

	helpers.it("journals both instant actions in physical order", function()
		local Engine = require("platform.remap.tap_hold_engine")
		local engine = Engine.new({ keys = { space = { hold_modifier = "shift" }, escape = { tap_action = "copy" },
			delete = { tap_action = "paste" } }, roll_keys = { "space" }, tap_min_ms = 0,
			lone_tap_max_ms = 0, one_shot_timeout_ms = 1000 })
		local origins = {}
		helpers.assert_true(engine:set_roll_origin_capture(function(code, at)
			local token = {}; origins[code] = token; return token
		end, function(token) return token ~= nil end))
		engine:process(SPACE, DOWN, 0)
		engine:process(1, DOWN, 10)
		local _, _, _, journal = engine:process(111, DOWN, 20)
		helpers.assert_eq(#journal, 3)
		helpers.assert_eq(journal[1].origin, origins[SPACE])
		helpers.assert_eq(journal[1].rows[1].code, SPACE)
		helpers.assert_eq(journal[2].tap, "copy")
		helpers.assert_eq(journal[2].binding, "tap_hold__escape")
		helpers.assert_eq(journal[2].origin, origins[1])
		helpers.assert_eq(journal[3].tap, "paste")
		helpers.assert_eq(journal[3].binding, "tap_hold__delete")
		helpers.assert_eq(journal[3].origin, origins[111])
	end)

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
