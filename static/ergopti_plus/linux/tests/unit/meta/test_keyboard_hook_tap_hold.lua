--- tests/unit/meta/test_keyboard_hook_tap_hold.lua

--- ==============================================================================
--- MODULE: Tap-Holds Through The Keyboard Hook
--- DESCRIPTION:
--- The engine's events must reach the application AND the daemon's own view of
--- the keyboard: a CapsLock held for Ctrl is Ctrl to the virtual keyboard and to
--- the modifier state, an Enter tapped on it is an Enter to the hotstrings, and
--- nothing the engine pressed survives a release request.
--- ==============================================================================

local helpers = require("tests.helpers")
local Engine = require("platform.remap.tap_hold_engine")

local EV_KEY = 1

local KEYS = {
	caps_lock = { tap_action = "enter", hold_modifier = "ctrl", time_activation_seconds = 10 },
	left_shift = { tap_action = "copy", hold_modifier = "shift", time_activation_seconds = 10 },
	left_alt = { tap_action = "backspace", hold_layer = "nav", time_activation_seconds = 10 },
}

--- Drives events through a fresh hook with the engine installed.
--- @param events table
--- @param extra table|nil callbacks
--- @return table emitted, table taps, table chars, table hook
local function drive(events, extra)
	local kh = helpers.load_module("adapters.keyboard_hook")
	-- A zero minimum tap: the drive has no clock between events.
	local engine = Engine.new({ keys = KEYS, tap_min_ms = 0, one_shot_timeout_ms = 2000 })
	local taps, emitted, chars = {}, {}, {}
	kh.set_remapper(engine, function(action) taps[#taps + 1] = action end)
	local callbacks = {
		onEmitRaw = function(code, value) emitted[#emitted + 1] = code .. ":" .. value; return true end,
		onChar = function(ch) chars[#chars + 1] = ch end,
	}
	for name, fn in pairs(extra and extra(kh) or {}) do callbacks[name] = fn end
	local stream = {}
	for index, pair in ipairs(events) do stream[index] = { type = EV_KEY, code = pair[1], value = pair[2] } end
	kh._test_drive(stream, callbacks, true)
	kh.set_remapper(nil)
	return table.concat(emitted, " "), taps, chars
end

helpers.describe("keyboard hook + tap-hold engine", function()

	helpers.it("sends Ctrl for a held CapsLock, never the lock itself", function()
		local emitted = drive({ { 58, 1 }, { 30, 1 }, { 30, 0 }, { 58, 0 } })
		helpers.assert_eq(emitted, "29:1 30:1 30:0 29:0", "CapsLock+A is Ctrl+A")
	end)

	helpers.it("types a real Enter for a tapped CapsLock, which the hotstrings see", function()
		local emitted, _, chars = drive({ { 58, 1 }, { 58, 0 } })
		helpers.assert_eq(emitted, "29:1 29:0 28:1 28:0")
		helpers.assert_eq(chars[1], "\n", "Enter reached the text path as a terminator")
	end)

	helpers.it("runs the tap action of a lone Shift and nothing after Shift+A", function()
		local _, taps = drive({ { 42, 1 }, { 42, 0 } })
		helpers.assert_eq(taps[1], "copy")
		local _, chord_taps = drive({ { 42, 1 }, { 30, 1 }, { 30, 0 }, { 42, 0 } })
		helpers.assert_eq(#chord_taps, 0)
	end)

	helpers.it("sends navigation chords while the layer key is held, and no Alt", function()
		local emitted = drive({ { 56, 1 }, { 36, 1 }, { 36, 0 }, { 56, 0 } })
		helpers.assert_eq(emitted, "29:1 105:1 105:0 29:0")
	end)

	helpers.it("releases a held Ctrl when asked, mid-hold", function()
		-- Ctrl+A arrives as a shortcut; the release is requested right there,
		-- while CapsLock is still physically down.
		local released_mid_hold = false
		drive({ { 58, 1 }, { 30, 1 } }, function(kh)
			return { onKey = function()
				kh.release_remapped()
				released_mid_hold = true
			end }
		end)
		helpers.assert_true(released_mid_hold, "the shortcut reached the hook")
		local emitted = drive({ { 58, 1 }, { 30, 1 }, { 30, 0 } }, function(kh)
			return { onKey = function() kh.release_remapped() end }
		end)
		helpers.assert_eq(emitted, "29:1 30:1 29:0 30:0", "Ctrl went up at the request, before A")
	end)

	helpers.it("swallows the release of a key the engine took before it was switched off", function()
		local emitted = {}
		drive({ { 58, 1 }, { 58, 0 } }, function(kh)
			return { onEmitRaw = function(code, value)
				emitted[#emitted + 1] = code .. ":" .. value
				if code == 29 and value == 1 then kh.set_remapper(nil) end
				return true
			end }
		end)
		helpers.assert_eq(table.concat(emitted, " "), "29:1 29:0",
			"Ctrl released at the switch, and no CapsLock up nothing pressed")
	end)

	helpers.it("forwards the release of a key pressed before the engine came in", function()
		local kh = helpers.load_module("adapters.keyboard_hook")
		local emitted = {}
		local engine = Engine.new({ keys = KEYS, tap_min_ms = 0, one_shot_timeout_ms = 2000 })
		kh._test_drive({ { type = EV_KEY, code = 58, value = 1 }, { type = EV_KEY, code = 58, value = 0 } }, {
			onEmitRaw = function(code, value)
				emitted[#emitted + 1] = code .. ":" .. value
				if code == 58 and value == 1 then kh.set_remapper(engine, function() end) end
				return true
			end,
		}, true)
		kh.set_remapper(nil)
		helpers.assert_eq(table.concat(emitted, " "), "58:1 58:0", "the key does not stay down")
	end)


	--- A lone Shift through a 350 ms engine; events are { value, kernel µs, read ms }.
	local function shift_taps(stream)
		local kh = helpers.load_module("adapters.keyboard_hook")
		local engine = Engine.new({ keys = { left_shift = { tap_action = "copy", hold_modifier = "shift",
			time_activation_seconds = 0.35 } }, tap_min_ms = 50, one_shot_timeout_ms = 2000 })
		local taps = {}
		kh.set_remapper(engine, function(action) taps[#taps + 1] = action end)
		local events = {}
		for index, ev in ipairs(stream) do
			events[index] = { type = EV_KEY, code = 42, value = ev[1], timestamp_us = ev[2], at_ms = ev[3] }
		end
		kh._test_drive(events, { onEmitRaw = function() return true end }, true)
		kh.set_remapper(nil)
		return taps
	end

	helpers.it("times a tap by when the keys moved, not by when the daemon read them", function()
		-- Measured in CI: a 100 ms Shift tap, its release read 500 ms after
		-- the press by a daemon busy elsewhere, sent Shift and never copied.
		local taps = shift_taps({ { 1, 1000000000, 0 }, { 0, 1000100000, 500 } })
		helpers.assert_eq(taps[1], "copy", "100 ms between the kernel's stamps is a tap")
		local held = shift_taps({ { 1, 1000000000, 0 }, { 0, 1000500000, 10 } })
		helpers.assert_eq(#held, 0, "500 ms between the stamps is a hold, however fast it was read")
	end)

end)
