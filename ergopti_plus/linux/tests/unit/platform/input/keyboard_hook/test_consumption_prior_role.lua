--- tests/unit/platform/input/keyboard_hook/test_consumption_prior_role.lua

--- ==============================================================================
--- MODULE: The key pressed just before, in the consumption detail (Linux)
--- DESCRIPTION:
--- The consumption detail names the modifier role of the key pressed just
--- before the current one (prior_role): "altgr" right after AltGr, false after
--- a key that is no modifier, another role after another modifier. A repeat
--- of the held AltGr is not a new press.
---
--- ROOT CAUSE ENCODED:
--- The script chords saw only AltGr held and their own key, so a fast « (# »
--- then Enter typed on Ergopti+ while AltGr was still down paused the driver
--- (the maintainer, 2026-11-17). A chord is AltGr pressed, then its key: the
--- consumer needs the key pressed just before, which only the hook sees.
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture")
local helpers, EV_KEY, ev = Fixture.helpers, Fixture.EV_KEY, Fixture.ev

-- evdev codes.
local KEY_RIGHTALT, KEY_LEFTSHIFT, KEY_ENTER, KEY_5 = 100, 42, 28, 6

--- Drives a stream through the real hook in intercept mode and returns the
--- prior_role of each Enter press offered to the consumption callback.
--- @param stream table Decoded events in arrival order.
--- @return table roles One entry per Enter press, "nil" when absent.
local function enter_prior_roles(stream)
	local hook = helpers.load_module("platform.input.keyboard_hook")
	local roles = {}
	hook._test_drive(stream, {
		captureEvent = function(_, value) if value ~= 0 then return "x", "x" end end,
		onConsume = function(detail)
			if detail.code == KEY_ENTER then roles[#roles + 1] = tostring(detail.prior_role) end
			return false
		end,
		onEmitRaw = function() return true end,
	}, true)
	return roles
end

helpers.describe("keyboard hook: the key pressed before a consumed press", function()
	helpers.it("prior-role: Enter right after AltGr names AltGr", function()
		helpers.assert_eq(table.concat(enter_prior_roles({
			ev(EV_KEY, KEY_RIGHTALT, 1), ev(EV_KEY, KEY_RIGHTALT, 2), ev(EV_KEY, KEY_ENTER, 1),
		}), ","), "altgr", "a repeat of the held AltGr is not a new press")
	end)

	helpers.it("prior-role: an AltGr symbol typed before Enter, AltGr still held, is not AltGr", function()
		helpers.assert_eq(table.concat(enter_prior_roles({
			ev(EV_KEY, KEY_RIGHTALT, 1), ev(EV_KEY, KEY_5, 1), ev(EV_KEY, KEY_5, 0), ev(EV_KEY, KEY_ENTER, 1),
		}), ","), "false")
	end)

	helpers.it("prior-role: another modifier pressed after AltGr is the key before", function()
		helpers.assert_eq(table.concat(enter_prior_roles({
			ev(EV_KEY, KEY_RIGHTALT, 1), ev(EV_KEY, KEY_LEFTSHIFT, 1), ev(EV_KEY, KEY_ENTER, 1),
			ev(EV_KEY, KEY_ENTER, 0), ev(EV_KEY, KEY_ENTER, 1),
		}), ","), "shift,false", "a second Enter follows the first, not AltGr")
	end)
end)
