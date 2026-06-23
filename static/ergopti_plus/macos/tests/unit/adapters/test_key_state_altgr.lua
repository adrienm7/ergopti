--- tests/unit/adapters/test_key_state_altgr.lua

--- ==============================================================================
--- MODULE: KeyState AltGr detection (regression)
--- DESCRIPTION:
--- Guards the script-control modifier guard that gates rcmd+Escape/Return/Backspace.
---
--- ROOT CAUSE ENCODED (script-control-altgr-leftmod):
--- is_right_altgr_held() accepted ONLY the right-hand command/option device masks.
--- A user who remaps their right command to option via their own Karabiner rules
--- holds a key that registers as a LEFT/plain option (deviceLeftAlternate). KE
--- still emitted the F15 escape sentinel, but the right-only guard returned false,
--- so script_control passed the sentinel through and rcmd+Escape (quit) silently
--- did nothing. The field log proved it: "Escape sentinel (F15) seen but no right
--- AltGr held — passing through." The guard only needs to tell a genuine chord
--- (any cmd/opt held) from a bare F13/F14/F15 keypress (no modifier), so it now
--- accepts a command OR option modifier on either side.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Distinct bits for each sided device mask so a raw value can encode exactly one.
local MASKS = {
	deviceRightCommand   = 0x01,
	deviceLeftCommand    = 0x02,
	deviceRightAlternate = 0x04,
	deviceLeftAlternate  = 0x08,
	deviceRightControl   = 0x10,
	deviceLeftControl    = 0x20,
	deviceRightShift     = 0x40,
	deviceLeftShift      = 0x80,
}

--- Loads key_state with checkKeyboardModifiers returning the given raw flag bits
--- and optional side-agnostic flags (e.g. { alt = true }) merged into the result.
local function load_with_raw(raw_bits, extra_flags)
	package.loaded["adapters.key_state"] = nil
	return helpers.load_with_stubs("adapters.key_state", {
		eventtap = {
			checkKeyboardModifiers = function(_)
				local mods = { _raw = raw_bits }
				if type(extra_flags) == "table" then
					for k, v in pairs(extra_flags) do mods[k] = v end
				end
				return mods
			end,
			event = { rawFlagMasks = MASKS },
		},
	})
end

helpers.describe("key_state.is_right_altgr_held accepts either-side cmd/option", function()
	helpers.it("returns true for a held LEFT option (the remapped-rcmd case)", function()
		local KS = load_with_raw(MASKS.deviceLeftAlternate)
		helpers.assert_true(KS.is_right_altgr_held(),
			"a held left option must qualify — a remapped right-cmd registers as left/plain option")
	end)

	helpers.it("returns true for a generic `alt` flag with NO device-side option bit", function()
		-- A Karabiner right-command→option remap can surface the held key only as the
		-- side-agnostic `alt` flag, setting no deviceLeftAlternate/deviceRightAlternate
		-- bit. The device-bit-only check missed it and the sentinel did nothing.
		local KS = load_with_raw(0, { alt = true })
		helpers.assert_true(KS.is_right_altgr_held(),
			"option held as a generic `alt` (no device bit) must still qualify as AltGr")
	end)

	helpers.it("returns false for a generic `cmd` flag with no device bit (plain Cmd)", function()
		local KS = load_with_raw(0, { cmd = true })
		helpers.assert_true(not KS.is_right_altgr_held(),
			"a generic command flag must not qualify — only option/right-command are AltGr")
	end)

	helpers.it("returns true for a held RIGHT option (the canonical ergopti remap)", function()
		local KS = load_with_raw(MASKS.deviceRightAlternate)
		helpers.assert_true(KS.is_right_altgr_held())
	end)

	helpers.it("returns true for a held RIGHT command", function()
		local KS = load_with_raw(MASKS.deviceRightCommand)
		helpers.assert_true(KS.is_right_altgr_held())
	end)

	helpers.it("returns false for a held LEFT command (plain Cmd — not AltGr)", function()
		-- Left command is the ordinary App-shortcut modifier; a stray Cmd + physical
		-- F-key must not be mistaken for a sentinel chord.
		local KS = load_with_raw(MASKS.deviceLeftCommand)
		helpers.assert_true(not KS.is_right_altgr_held(),
			"plain left command must not qualify as an AltGr sentinel modifier")
	end)

	helpers.it("returns false when no command/option is held (bare F-key press)", function()
		local KS = load_with_raw(0)
		helpers.assert_true(not KS.is_right_altgr_held(),
			"a bare sentinel keypress with no modifier must still be rejected")
	end)

	helpers.it("returns false when only shift/control is held (not a chord)", function()
		local KS = load_with_raw(MASKS.deviceLeftShift | MASKS.deviceRightControl)
		helpers.assert_true(not KS.is_right_altgr_held(),
			"shift/control alone must not qualify as an AltGr chord")
	end)
end)

helpers.describe("key_state.describe_held_modifiers names the held side", function()
	helpers.it("reports a left option as 'lopt'", function()
		local KS = load_with_raw(MASKS.deviceLeftAlternate)
		helpers.assert_eq(KS.describe_held_modifiers(), "lopt")
	end)

	helpers.it("reports '(none)' when nothing is held", function()
		local KS = load_with_raw(0)
		helpers.assert_eq(KS.describe_held_modifiers(), "(none)")
	end)

	helpers.it("tags a generic option flag with no device bit as 'alt(generic)'", function()
		local KS = load_with_raw(0, { alt = true })
		helpers.assert_eq(KS.describe_held_modifiers(), "alt(generic)")
	end)

	helpers.it("does NOT double-report when a device bit and its generic flag both set", function()
		local KS = load_with_raw(MASKS.deviceLeftAlternate, { alt = true })
		helpers.assert_eq(KS.describe_held_modifiers(), "lopt")
	end)

	helpers.it("lists multiple held modifiers in side order", function()
		local KS = load_with_raw(MASKS.deviceRightCommand | MASKS.deviceLeftAlternate)
		helpers.assert_eq(KS.describe_held_modifiers(), "rcmd lopt")
	end)
end)
