--- tests/unit/platform/input/keyboard_hook/test_action_one_shot.lua

--- ==============================================================================
--- MODULE: One-Shot Shift From An Action Origin
--- DESCRIPTION:
--- The one-shot Shift is a generic catalogue action on every OS (decision of
--- 2026-11-06). On Linux only a key frame could arm the tap-hold engine, so a
--- gesture or a pointer button bound to it did nothing. The hook now arms the
--- installed engine for such an origin, with a guard tied to that engine and
--- its remapper generation: the next key spends the arm, the engine's timeout
--- drops it, and a pause (which uninstalls the engine) voids it.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")

local EV_KEY = 1
local KEY_A, KEY_LEFTSHIFT = 30, 42

--- An engine with no tap-hold key, typing « A » as Shift+A on the same key.
--- @return table
local function plain_engine()
	return Engine.new({ keys = {}, tap_min_ms = 0, lone_tap_max_ms = 0, one_shot_timeout_ms = 2000,
		key_text = function(code) return code == KEY_A and "a" or nil end,
		plan_text = function(text)
			if text == "A" then return { { keycode = KEY_A, mods = { "shift" } } } end
			return nil
		end,
		one_shot_result = function() return nil end })
end

--- Drives { code, value, kernel ms } events through the hook with `engine`
--- installed; `on_emit` runs after every event the virtual keyboard receives.
--- @return string What the virtual keyboard received.
local function drive(kh, events, on_emit)
	local emitted, stream = {}, {}
	for index, ev in ipairs(events) do
		stream[index] = { type = EV_KEY, code = ev[1], value = ev[2], timestamp_us = ev[3] * 1000 }
	end
	kh._test_drive(stream, {
		onEmitRaw = function(code, value)
			emitted[#emitted + 1] = code .. ":" .. value
			if on_emit then on_emit() end
			return true
		end,
	}, true)
	return table.concat(emitted, " ")
end

--- Arms after the first output, as a gesture fired meanwhile.
--- @return function on_emit, table result { armed = boolean|nil }
local function arm_once(kh)
	local result = {}
	return function()
		if result.armed == nil then result.armed, result.refusal = kh.arm_action_one_shot() end
	end, result
end

local SHIFTED_A = KEY_LEFTSHIFT .. ":1 " .. KEY_A .. ":1 " .. KEY_A .. ":0 " .. KEY_LEFTSHIFT .. ":0"

helpers.describe("keyboard hook: one-shot Shift from an action origin (one-shot-action-origin)", function()

	helpers.it("arms from a gesture and spends the arm on the next key", function()
		local kh = helpers.load_module("platform.input.keyboard_hook")
		kh.set_remapper(plain_engine(), function() end)
		local on_emit, result = arm_once(kh)
		local first = drive(kh, { { KEY_A, 1, 1000 }, { KEY_A, 0, 1010 } }, on_emit)
		helpers.assert_eq(result.refusal, nil, "the installed engine accepts the arm")
		helpers.assert_true(result.armed)
		helpers.assert_eq(first, KEY_A .. ":1 " .. KEY_A .. ":0", "control: the key before the arm is typed as it is")
		helpers.assert_eq(drive(kh, { { KEY_A, 1, 1100 }, { KEY_A, 0, 1110 } }), SHIFTED_A,
			"the next key is typed under the one-shot Shift")
		helpers.assert_eq(drive(kh, { { KEY_A, 1, 1200 }, { KEY_A, 0, 1210 } }), KEY_A .. ":1 " .. KEY_A .. ":0",
			"the arm is spent: the key after it is plain")
		kh.set_remapper(nil)
	end)

	helpers.it("lets the arm lapse at the engine's timeout", function()
		local kh = helpers.load_module("platform.input.keyboard_hook")
		kh.set_remapper(plain_engine(), function() end)
		local on_emit, result = arm_once(kh)
		drive(kh, { { KEY_A, 1, 1000 }, { KEY_A, 0, 1010 } }, on_emit)
		helpers.assert_true(result.armed)
		helpers.assert_eq(drive(kh, { { KEY_A, 1, 5000 }, { KEY_A, 0, 5010 } }), KEY_A .. ":1 " .. KEY_A .. ":0",
			"a key typed after the timeout is plain")
		kh.set_remapper(nil)
	end)

	helpers.it("is voided by a pause, which uninstalls the engine", function()
		local kh = helpers.load_module("platform.input.keyboard_hook")
		local engine = plain_engine()
		kh.set_remapper(engine, function() end)
		local on_emit, result = arm_once(kh)
		drive(kh, { { KEY_A, 1, 1000 }, { KEY_A, 0, 1010 } }, on_emit)
		helpers.assert_true(result.armed)
		kh.set_remapper(nil)
		kh.set_remapper(engine, function() end)
		helpers.assert_eq(drive(kh, { { KEY_A, 1, 1100 }, { KEY_A, 0, 1110 } }), KEY_A .. ":1 " .. KEY_A .. ":0",
			"the engine installed again after the pause keeps no arm")
		kh.set_remapper(nil)
	end)

	helpers.it("refuses without an installed engine or a running hook", function()
		local kh = helpers.load_module("platform.input.keyboard_hook")
		local armed, refusal = kh.arm_action_one_shot()
		helpers.assert_eq(armed, false, "a stopped hook arms nothing")
		helpers.assert_true(type(refusal) == "string" and refusal ~= "", "and says why")
	end)
end)
