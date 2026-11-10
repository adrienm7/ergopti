--- tests/unit/platform/remap/tap_hold/test_key_combination_first_key_order.lua

--- ==============================================================================
--- MODULE: Ordered Pair First Key Order
--- DESCRIPTION:
--- With several first keys of a pair held, Windows runs the pair of the key
--- pressed earliest (KeyCombinationHeldFirstKey reads the press ledger); the
--- shared policy took the first held key in catalogue order instead, so
--- LShift, then CapsLock, then Space ran CapsLock's pair.
--- ==============================================================================

local helpers = require("tests.helpers")
local Policy = require("tap_hold.key_combinations")

local KEYS = { "escape", "tab", "caps_lock", "left_shift", "left_ctrl", "win", "left_alt", "space", "alt_gr",
	"right_ctrl", "right_shift", "enter", "backspace", "delete" }




helpers.describe("ordered pairs: the earliest held first key", function()

	local function policy()
		local thresholds = {}
		for _, key in ipairs(KEYS) do thresholds[key] = 200 end
		return Policy.new({ keys = KEYS, thresholds = thresholds, revision = 1, generation = 1, enabled = true,
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
