--- tests/unit/platform/remap/tap_hold/test_tap_hold_space_end_char.lua

--- ==============================================================================
--- MODULE: Space Tap-Hold Completes An End-Character Trigger (Linux)
--- DESCRIPTION:
--- A Space tap must complete a hotstring trigger exactly like a plain Space; only
--- the hold runs the action. The real keyboard hook with the real tap-hold engine
--- feeds the real shared hotstring engine, as the daemon wires them, once with
--- Space left to itself and once with Space a tap-hold key.
--- ==============================================================================

local helpers = require("tests.helpers")

local EV_KEY = 1
local K = { q = 16, z = 44, x = 45, space = 57, lctrl = 29 }
local LETTERS = { [K.q] = "q", [K.z] = "z", [K.x] = "x", [K.space] = " " }

--- Types the events through the hook into an engine holding one end-character
--- trigger and returns what the application shows.
--- @param events table Array of { code, value, at_ms }.
--- @param space_tap_hold boolean Whether Space is a tap-hold key.
--- @return string screen
local function type_events(events, space_tap_hold)
	local engine = require("modules.hotstrings.engine").new()
	assert(engine:load_mappings({ { auto_expand = false, trigger = "qzx", replacement = "final" } }),
		"the fixture mapping must publish")
	local kh = helpers.load_module("adapters.keyboard_hook")
	if space_tap_hold then
		local TapHoldEngine = require("platform.remap.tap_hold_engine")
		kh.set_remapper(TapHoldEngine.new({
			keys = { space = { tap_action = "space", hold_modifier = "ctrl", time_activation_seconds = 10 } },
			tap_min_ms = 0, one_shot_timeout_ms = 2000,
			nav_layer = require("tests.support.nav_layer_fixture").recommended(),
		}), function() end)
	end
	local text = {}
	local stream = {}
	for index, e in ipairs(events) do stream[index] = { type = EV_KEY, code = e[1], value = e[2], at_ms = e[3] } end
	local ok, err = pcall(kh._test_drive, stream, {
		captureEvent = function(code, value)
			local letter = LETTERS[code]
			if value == 0 or not letter then return nil, nil, nil end
			return letter, letter, nil
		end,
		onEmitRaw = function() return true end,
		onChar = function(ch)
			text[#text + 1] = ch
			-- As the daemon calls it: a Space is a terminator, replayed after the
			-- replacement when the entry does not consume it.
			local result = engine:on_char(ch, { is_terminator = ch == " ", terminator_consumed = false })
			if result then
				for _ = 1, result.backspace_count do table.remove(text) end
				text[#text + 1] = result.replacement .. (result.terminator or "")
			end
		end,
	}, true)
	kh.set_remapper(nil)
	assert(ok, err)
	return table.concat(text)
end

local TRIGGER_THEN_SPACE = {
	{ K.q, 1, 0 }, { K.q, 0, 10 }, { K.z, 1, 20 }, { K.z, 0, 30 }, { K.x, 1, 40 }, { K.x, 0, 50 },
	{ K.space, 1, 100 }, { K.space, 0, 140 },
}

helpers.describe("space tap-hold: an end-character trigger", function()
	helpers.it("a plain Space completes the trigger (the reference behaviour)", function()
		helpers.assert_eq(type_events(TRIGGER_THEN_SPACE, false), "final ", "a plain Space ends the trigger")
	end)

	helpers.it("a Space tap completes the trigger exactly like a plain Space", function()
		helpers.assert_eq(type_events(TRIGGER_THEN_SPACE, true), "final ",
			"the Space tap-hold's tap must end the trigger as a plain Space does")
	end)

	helpers.it("a Space hold does not complete the trigger", function()
		local held = {
			{ K.q, 1, 0 }, { K.q, 0, 10 }, { K.z, 1, 20 }, { K.z, 0, 30 }, { K.x, 1, 40 }, { K.x, 0, 50 },
			{ K.space, 1, 100 }, { K.space, 0, 20000 },
		}
		helpers.assert_eq(type_events(held, true):find("final", 1, true), nil,
			"a hold is the action, not a space")
	end)
end)
