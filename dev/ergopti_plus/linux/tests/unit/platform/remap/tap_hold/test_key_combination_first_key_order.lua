--- tests/unit/platform/remap/tap_hold/test_key_combination_first_key_order.lua

--- ==============================================================================
--- MODULE: Ordered Pair First Key Order and Tap Minimum
--- DESCRIPTION:
--- With several first keys of a pair held, Windows runs the pair of the key
--- pressed earliest (KeyCombinationHeldFirstKey reads the press ledger); the
--- shared policy took the first held key in catalogue order instead, so
--- LShift, then CapsLock, then Space ran CapsLock's pair. A pair with a hold
--- judges its tap at the second key's release, and the tap minimum applies to
--- every such tap (decision of 2026-11-10; Windows TapHoldOwnImmediateModifier
--- checks it too): a 20 ms bounce ran the pair's tap.
--- ==============================================================================

local helpers = require("tests.helpers")
local Policy = require("tap_hold.engine.key_combinations")

local KEYS = { "escape", "tab", "caps_lock", "left_shift", "left_ctrl", "win", "left_alt", "space", "alt_gr",
	"right_ctrl", "right_shift", "enter", "backspace", "delete" }




helpers.describe("ordered pairs: the earliest held first key", function()

	local function policy()
		local thresholds = {}
		for _, key in ipairs(KEYS) do thresholds[key] = 200 end
		return Policy.new({ keys = KEYS, thresholds = thresholds, tap_min_ms = 50, revision = 1, generation = 1, enabled = true,
			taps = { caps_lock_then_space = "copy", left_shift_then_space = "paste" }, holds = {} })
	end

	local function press(owner, key, value, at_ms)
		local result = owner.process({ key = key, value = value, at_ms = at_ms, physical = true, source = "kbd",
			generation = 1, revision = 1 })
		for _, effect in ipairs(result.effects) do
			if effect.kind == "tap" then return effect.pair_id end
		end
		return nil
	end

	helpers.it("runs the pair of the first key pressed earliest (pair-first-key-press-order)", function()
		local owner = policy()
		press(owner, "left_shift", 1, 0)
		press(owner, "caps_lock", 1, 100)
		helpers.assert_eq(press(owner, "space", 1, 200), "left_shift_then_space", "LShift went down first")
	end)

	helpers.it("still follows the press order the other way round (pair-first-key-press-order)", function()
		local owner = policy()
		press(owner, "caps_lock", 1, 0)
		press(owner, "left_shift", 1, 100)
		helpers.assert_eq(press(owner, "space", 1, 200), "caps_lock_then_space", "CapsLock went down first")
	end)

	helpers.it("forgets a released first key (pair-first-key-press-order)", function()
		local owner = policy()
		press(owner, "left_shift", 1, 0)
		press(owner, "caps_lock", 1, 100)
		press(owner, "left_shift", 0, 150)
		helpers.assert_eq(press(owner, "space", 1, 200), "caps_lock_then_space", "only CapsLock is still held")
	end)

end)




helpers.describe("ordered pairs: the tap minimum", function()

	local function policy()
		local thresholds = {}
		for _, key in ipairs(KEYS) do thresholds[key] = 200 end
		return Policy.new({ keys = KEYS, thresholds = thresholds, tap_min_ms = 50, revision = 1, generation = 1,
			enabled = true, taps = { right_ctrl_then_right_shift = "copy" },
			holds = { right_ctrl_then_right_shift = "shift" } })
	end

	local function tap_at(release_ms)
		local owner = policy()
		local function send(key, value, at_ms)
			return owner.process({ key = key, value = value, at_ms = at_ms, physical = true, source = "kbd",
				generation = 1, revision = 1 })
		end
		send("right_ctrl", 1, 0)
		send("right_shift", 1, 10)
		for _, effect in ipairs(send("right_shift", 0, 10 + release_ms).effects) do
			if effect.kind == "tap" then return effect.pair_id end
		end
		return nil
	end

	helpers.it("runs no pair tap on a release sooner than the minimum (pair-tap-minimum)", function()
		helpers.assert_nil(tap_at(20), "a 20 ms bounce is no tap")
		helpers.assert_eq(tap_at(50), "right_ctrl_then_right_shift", "the minimum itself taps")
		helpers.assert_eq(tap_at(120), "right_ctrl_then_right_shift", "a quick release taps")
		helpers.assert_nil(tap_at(250), "past the threshold it was a hold")
	end)

end)
