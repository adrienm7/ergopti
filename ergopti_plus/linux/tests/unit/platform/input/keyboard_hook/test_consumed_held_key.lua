--- tests/unit/platform/input/keyboard_hook/test_consumed_held_key.lua

--- ==============================================================================
--- MODULE: Consumed Press Held On The Wire (Linux)
--- DESCRIPTION:
--- « Touches de jeu » (maintainer decision of 2026-11-26): a consumer may hold
--- another key on the wire in a consumed press's place (hold_code), the layout
--- emulation's held key. The real reader over a recorded syscall backend feeds
--- the hook, and the assertion is on the exact (code, value) pairs written to
--- the virtual keyboard.
---
--- ROOT CAUSE ENCODED:
--- The emulation typed each emulated character as a tap in the press's place
--- (down and up at once, again on every repeat, nothing on the release), so a
--- game saw a stream of taps and nothing could be held. Each case below is RED
--- on that code: the press now writes one down, each repeat one repeat, the
--- release one up, and a reset that already released the key owes no second up
--- (no stuck key and no runaway repeat).
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture")
local helpers, EV_KEY, ev =
	Fixture.helpers, Fixture.EV_KEY, Fixture.ev

-- KEY_J is pressed; the consumer holds KEY_E (18) in its place.
local KEY_J, KEY_E = 36, 18

helpers.describe("keyboard hook: a consumed press held on the wire", function()
	local function drive(stream, receipt_of)
		local previous = package.loaded["hotstrings.engine.device_finder"]
		local state = { wire = {}, repeats = 0 }
		package.loaded["hotstrings.engine.device_finder"] = {
			physical_sources = function(paths)
				return { { path = paths[1], sysfs = "/sys/probe/keyboard", name = "fixture keyboard", physical = true } }
			end,
		}
		local ok, err = pcall(function()
			local hook = helpers.load_module("platform.input.keyboard_hook")
			local primed = false
			hook._test_drive(stream, {
				captureEvent = function(_, value)
					if not primed then hook.physical_source_receipt(); primed = true end
					if value ~= 0 then return "j", "j" end
				end,
				onConsume = function(detail)
					return receipt_of(state, detail)
				end,
				onEmitRaw = function(code, value)
					state.wire[#state.wire + 1] = code .. ":" .. value
					return true
				end,
			}, true)
		end)
		package.loaded["hotstrings.engine.device_finder"] = previous
		if not ok then error(err, 0) end
		return state
	end

	local function held(state)
		return { consume = true, hold_code = KEY_E,
			repeat_callback = function() state.repeats = state.repeats + 1; return true end,
			after_hold = function() state.wire[#state.wire + 1] = "after" end }
	end

	helpers.it("writes the held key's down on the press and its up on the release (game-keys-held)", function()
		local state = drive({ ev(EV_KEY, KEY_J, 1), ev(EV_KEY, KEY_J, 0) }, held)
		helpers.assert_eq(state.wire, { "18:1", "after", "18:0" },
			"one down, the character path after it, one up on the physical release")
	end)

	helpers.it("repeats the held key with the physical key, never as a new tap (game-keys-held)", function()
		local state = drive({ ev(EV_KEY, KEY_J, 1), ev(EV_KEY, KEY_J, 2), ev(EV_KEY, KEY_J, 2), ev(EV_KEY, KEY_J, 0),
			ev(EV_KEY, KEY_J, 1), ev(EV_KEY, KEY_J, 0) }, held)
		helpers.assert_eq(state.wire, { "18:1", "after", "18:2", "18:2", "18:0", "18:1", "after", "18:0" },
			"repeats stay downs of the held key; each press gets exactly one up")
		helpers.assert_eq(state.repeats, 2, "the consumer hears of each repeat the wire took")
	end)

	helpers.it("refuses a malformed held key and lets the press through (game-keys-held)", function()
		local state = drive({ ev(EV_KEY, KEY_J, 1), ev(EV_KEY, KEY_J, 0) }, function(observed)
			local receipt = held(observed)
			receipt.hold_code = 0x400
			return receipt
		end)
		helpers.assert_eq(state.wire, { "36:1", "36:0" }, "no receipt: the physical key passes as itself")
		local orphan = drive({ ev(EV_KEY, KEY_J, 1), ev(EV_KEY, KEY_J, 0) }, function(observed)
			local receipt = held(observed)
			receipt.hold_code = nil
			return receipt
		end)
		helpers.assert_eq(orphan.wire, { "36:1", "36:0" }, "after_hold without hold_code is no receipt either")
	end)

	helpers.it("keeps a plain consumed press off the wire (game-keys-held)", function()
		local state = drive({ ev(EV_KEY, KEY_J, 1), ev(EV_KEY, KEY_J, 2), ev(EV_KEY, KEY_J, 0) }, function(observed)
			return { consume = true, repeat_callback = function() observed.repeats = observed.repeats + 1; return true end }
		end)
		helpers.assert_eq(state.wire, {}, "a receipt without hold_code writes nothing")
		helpers.assert_eq(state.repeats, 1)
	end)
end)
