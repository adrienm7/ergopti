--- tests/unit/platform/input/keyboard_hook/test_held_modifier_key.lua

--- ==============================================================================
--- MODULE: Caps Lock and AltGr held as a custom modifier (Linux)
--- DESCRIPTION:
--- While the layout emulation holds a custom modifier on Caps Lock or AltGr
--- (Neo's Mod3 and Mod4), the hook takes the key as a plain key of its owner:
--- XKB never sees it, so Caps Lock never toggles and AltGr selects no XKB
--- level, the application never receives it, and its repeats and its release
--- go to the owner. A layout holding nothing there keeps both roles.
---
--- ROOT CAUSE ENCODED:
--- The hook forwarded every modifier and Caps Lock raw before any consumer
--- could see it, so the emulation could hold Mod3 and Mod4 only on the ISO key
--- left of Enter and the key right of left Shift (layout-levels-emulation).
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture")
local helpers, EV_KEY, ev = Fixture.helpers, Fixture.EV_KEY, Fixture.ev

-- evdev codes.
local KEY_CAPSLOCK, KEY_RIGHTALT, KEY_A = 58, 100, 30

--- Drives a stream through the real hook in intercept mode.
--- @param stream table Decoded events in arrival order.
--- @param holds boolean Whether the emulation holds a modifier on Caps Lock and AltGr.
--- @return table seen { captured, emitted, owner, altgr_under } as code:value strings.
local function drive(stream, holds)
	local hook = helpers.load_module("platform.input.keyboard_hook")
	local seen = { captured = {}, emitted = {}, owner = {}, altgr_under = {} }
	hook._test_drive(stream, {
		captureEvent = function(code, value)
			seen.captured[#seen.captured + 1] = code .. ":" .. value
			if value ~= 0 then return "x", "x" end
		end,
		onHeldModifierKey = function(detail)
			if not holds then return nil end
			seen.owner[#seen.owner + 1] = detail.code .. ":down"
			return { consume = true,
				repeat_callback = function(event) seen.owner[#seen.owner + 1] = event.code .. ":repeat"; return true end,
				release_callback = function(event) seen.owner[#seen.owner + 1] = event.code .. ":up"; return true end }
		end,
		onConsume = function(detail)
			if detail.code == KEY_A then seen.altgr_under[#seen.altgr_under + 1] = tostring(detail.mods.altgr == true) end
			return false
		end,
		onEmitRaw = function(code, value) seen.emitted[#seen.emitted + 1] = code .. ":" .. value; return true end,
	}, true)
	return seen
end

--- Whether a list holds an entry of a code.
local function names(list, code)
	for _, entry in ipairs(list) do
		if entry:match("^(%d+):") == tostring(code) then return true end
	end
	return false
end

local STREAM = {
	ev(EV_KEY, KEY_CAPSLOCK, 1), ev(EV_KEY, KEY_CAPSLOCK, 2), ev(EV_KEY, KEY_CAPSLOCK, 0),
	ev(EV_KEY, KEY_RIGHTALT, 1), ev(EV_KEY, KEY_A, 1), ev(EV_KEY, KEY_A, 0), ev(EV_KEY, KEY_RIGHTALT, 0),
}

helpers.describe("keyboard hook: Caps Lock and AltGr held as a custom modifier", function()
	helpers.it("layout-levels-emulation: the held keys reach their owner, never XKB or the application", function()
		local seen = drive(STREAM, true)
		helpers.assert_eq(table.concat(seen.owner, ","), "58:down,58:repeat,58:up,100:down,100:up",
			"the owner gets each press, repeat and release")
		helpers.assert_true(not names(seen.captured, KEY_CAPSLOCK), "XKB never toggles Caps Lock")
		helpers.assert_true(not names(seen.captured, KEY_RIGHTALT), "XKB never selects the AltGr level")
		helpers.assert_true(not names(seen.emitted, KEY_CAPSLOCK) and not names(seen.emitted, KEY_RIGHTALT),
			"the application never receives either key")
		helpers.assert_eq(table.concat(seen.altgr_under, ","), "false", "a key under it reports no AltGr")
		helpers.assert_true(names(seen.emitted, KEY_A), "the key under it still passes")
	end)

	helpers.it("ergopti-emulation-unchanged: a layout holding nothing there keeps the lock and AltGr", function()
		local seen = drive(STREAM, false)
		helpers.assert_eq(#seen.owner, 0)
		helpers.assert_true(names(seen.captured, KEY_CAPSLOCK) and names(seen.captured, KEY_RIGHTALT),
			"XKB sees both keys as before")
		for _, entry in ipairs({ "58:1", "58:0", "100:1", "100:0" }) do
			local found = false
			for _, emitted in ipairs(seen.emitted) do found = found or emitted == entry end
			helpers.assert_true(found, entry .. " reaches the application as before")
		end
		helpers.assert_eq(table.concat(seen.altgr_under, ","), "true", "a key under AltGr reports it")
	end)
end)
