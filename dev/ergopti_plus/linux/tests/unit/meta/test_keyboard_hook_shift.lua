--- tests/unit/meta/test_keyboard_hook_shift.lua

--- ==============================================================================
--- MODULE: Keyboard Hook Shift-Tracking Regression Guard
--- DESCRIPTION:
--- Guards that the keyboard hook tracks Shift state from key transitions
--- (down sets, release clears) instead of treating it as a per-key one-shot
--- that force-resets after every printable character.
---
--- ROOT CAUSE ENCODED:
--- _pump_one() set _shift_held=true on Shift-down but force-reset
--- _shift_held=false after resolving each printable key. Key releases were
--- early-dropped before tracking, so the only thing that cleared _shift_held
--- was the next keydown. Holding Shift while typing multiple letters ('A','B')
--- produced 'Ab' instead of 'AB'.
---
--- The fix processes modifier key releases (setting the flag false) and
--- removes the unconditional per-key reset so a held Shift correctly
--- capitalises every letter while held.
---
--- HOW THIS TEST IS GENUINE (not a delivery-only tautology):
--- input_reader.resolve_char(code, layout, shift) is the sink that decides
--- case from the shift flag, but it does not load in isolation. So we replace
--- it with a recording stub that captures the shift flag it receives for each
--- resolved keycode. The primary case (Shift held across two letters, no
--- release) is RED before the fix — the second letter records shift=false —
--- and GREEN after — both record shift=true.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Saved so the recording stub does not leak into other Linux tests that need
-- the real input_reader (load_module only wipes the named module, not deps).
local _saved_ir = package.loaded["modules.hotstrings.input_reader"]

--- Installs a fake input_reader whose resolve_char records the shift flag it
--- receives per keycode. Must be called BEFORE load_module pumps a char.
--- @return table shift_seen Ordered list of the shift flag per resolved letter.
local function install_recording_input_reader()
	local shift_seen = {}
	package.loaded["modules.hotstrings.input_reader"] = {
		new = function() return {} end,
		resolve_char = function(_code, _layout, shift)
			shift_seen[#shift_seen + 1] = shift and true or false
			-- Distinguishable char so on_char still delivers something.
			return shift and "U" or "l"
		end,
	}
	return shift_seen
end

--- Loads a fresh keyboard_hook and pumps one evtest line per event.
--- @param lines table Evtest-format event lines in arrival order.
--- @return table received The chars delivered to on_char.
local function pump_lines(lines)
	local kh = helpers.load_module("adapters.keyboard_hook")
	local received = {}
	local idx = 0
	local pipe = { read = function() idx = idx + 1; return lines[idx] end }
	for _ = 1, #lines do
		kh._test_inject_and_pump(pipe, function(ch) received[#received + 1] = ch end, true)
	end
	return received
end


helpers.describe("keyboard_hook: shift tracking from key transitions", function()

	helpers.it("keeps Shift held across two letters (both resolved shifted)", function()
		local shift_seen = install_recording_input_reader()
		local received = pump_lines({
			"Event: code 42 (KEY_LEFTSHIFT), value 1",  -- Shift down
			"Event: code 30 (KEY_A), value 1",           -- A down (shift held)
			"Event: code 48 (KEY_B), value 1",           -- B down (shift STILL held)
		})
		-- The old code force-reset _shift_held after the first printable key, so
		-- B resolved unshifted. Assert BOTH letters saw a held Shift — this is
		-- RED before the fix (shift_seen would be {true, false}).
		helpers.assert_eq(#shift_seen, 2, "two letters must be resolved")
		helpers.assert_true(shift_seen[1] == true, "A must resolve with Shift held")
		helpers.assert_true(shift_seen[2] == true,
			"B must ALSO resolve with Shift held (carried across keys, not one-shot)")
		helpers.assert_eq(received[1], "U", "A delivered as the shifted char")
		helpers.assert_eq(received[2], "U", "B delivered as the shifted char")
	end)

	helpers.it("clears Shift on real release so the next letter is unshifted", function()
		local shift_seen = install_recording_input_reader()
		pump_lines({
			"Event: code 42 (KEY_LEFTSHIFT), value 1",   -- Shift down
			"Event: code 30 (KEY_A), value 1",             -- A down (shift held)
			"Event: code 42 (KEY_LEFTSHIFT), value 0",     -- Shift up (release)
			"Event: code 48 (KEY_B), value 1",             -- B down (NOT shifted)
		})
		-- Verifies the release path actually clears the flag (the fix processes
		-- releases instead of early-dropping them).
		helpers.assert_eq(#shift_seen, 2, "two letters must be resolved")
		helpers.assert_true(shift_seen[1] == true, "A resolves with Shift held")
		helpers.assert_true(shift_seen[2] == false,
			"B resolves UNSHIFTED after the real Shift release")
	end)

end)


-- Restore the real input_reader entry so the recording stub does not leak.
package.loaded["modules.hotstrings.input_reader"] = _saved_ir
