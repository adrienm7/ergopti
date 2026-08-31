--- tests/unit/adapters/test_key_state_altgr.lua

--- ==============================================================================
--- MODULE: KeyState AltGr detection (regression)
--- DESCRIPTION:
--- Guards the script-control modifier guard that gates rcmd+Escape/Return/Backspace.
---
--- HISTORY (script-control-altgr-leftmod, then F-HIGH-22):
--- is_right_altgr_held() originally accepted ONLY the right-hand command/option
--- device masks. A user who remaps their right command to option via their own
--- Karabiner rules holds a key that registers as a LEFT/plain option
--- (deviceLeftAlternate); the right-only guard returned false and rcmd+Escape/
--- Return/Backspace silently did nothing (script-control-altgr-leftmod). Two
--- follow-up commits progressively widened the mask to also accept
--- deviceLeftAlternate and then a side-agnostic `mods.alt == true` fallback with
--- NO device bit at all — but that widening regressed a CRITICAL invariant
--- (F-HIGH-22): holding plain LEFT Option (no right-hand modifier whatsoever)
--- while pressing a physical F13/F14/F15 key now ALSO read as "genuine",
--- dispatching script_pause/reload/quit from a chord that was never meant to be
--- a sentinel.
---
--- The fix narrows is_right_altgr_held() strictly back to right-hand-only device
--- masks (deviceRightCommand | deviceRightAlternate). The remapped-rcmd scenario
--- that motivated the original widening is now covered by a DIFFERENT, safer
--- mechanism: sentinel_is_tagged() in script_control.lua, which checks that the
--- KE-emitted sentinel event itself carries the ctrl+shift
--- SCRIPT_CONTROL_SENTINEL_TAGS output modifiers that every genuine sentinel rule
--- stamps (karabiner/generator.lua). sentinel_is_genuine() accepts EITHER this
--- narrowed live-modifier check OR the tag, so genuine right-command-remapped-to-
--- option chords still dispatch correctly — see test_script_control.lua's
--- F-CRIT-1 describe block for the tag-based coverage.
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

helpers.describe("key_state.is_right_altgr_held is strictly right-hand-only (F-HIGH-22)", function()
	-- F-HIGH-22 regression guard: a held LEFT option must NOT qualify. The prior
	-- widening accepted deviceLeftAlternate so a remapped-rcmd chord would pass,
	-- but that also meant a plain left-Option hold (no right-hand modifier at
	-- all) plus a physical F13/F14/F15 press dispatched script_pause/reload/quit
	-- unintentionally. The remapped-rcmd scenario is now covered by
	-- sentinel_is_tagged() in script_control.lua instead (see test_script_control.lua).
	helpers.it("returns FALSE for a held LEFT option (F-HIGH-22 — must not be mistaken for a sentinel)", function()
		local KS = load_with_raw(MASKS.deviceLeftAlternate)
		helpers.assert_true(not KS.is_right_altgr_held(),
			"a held left option must NOT qualify — sentinel_is_tagged() covers the remapped-rcmd case instead (F-HIGH-22)")
	end)

	-- F-HIGH-22 regression guard: a generic `alt` flag with no device bit (which a
	-- bare physical Option key legitimately produces) must NOT qualify either —
	-- this was the exact widening that let a plain left-Option + F15 dispatch
	-- script_quit.
	helpers.it("returns FALSE for a generic `alt` flag with NO device-side option bit (F-HIGH-22)", function()
		local KS = load_with_raw(0, { alt = true })
		helpers.assert_true(not KS.is_right_altgr_held(),
			"a generic `alt` flag with no device bit must NOT qualify as AltGr (F-HIGH-22)")
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

helpers.describe("key_state.get_shift_side samples device-specific state", function()
	helpers.it("reports a held right Shift", function()
		local KS = load_with_raw(MASKS.deviceRightShift, { shift = true })
		helpers.assert_eq(KS.get_shift_side(), "right")
	end)

	helpers.it("reports a held left Shift", function()
		local KS = load_with_raw(MASKS.deviceLeftShift, { shift = true })
		helpers.assert_eq(KS.get_shift_side(), "left")
	end)

	helpers.it("returns nil for no Shift or simultaneous Shift sides", function()
		helpers.assert_eq(load_with_raw(0).get_shift_side(), nil)
		helpers.assert_eq(load_with_raw(
			MASKS.deviceLeftShift | MASKS.deviceRightShift,
			{ shift = true }).get_shift_side(), nil)
	end)
end)
