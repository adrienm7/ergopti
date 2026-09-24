--- tests/unit/meta/test_tap_hold_loader.lua

--- ==============================================================================
--- MODULE: Tap-Hold Configuration Rules
--- DESCRIPTION:
--- The user's tap_hold.toml laid over the shared defaults, with the Windows
--- loader's rules. The kanata path merged field by field and kept both a
--- default modifier and a chosen layer, so choosing the navigation layer on
--- CapsLock left it Ctrl; "none" could not clear a hold either.
--- ==============================================================================

local helpers = require("tests.helpers")
local Config = require("platform.remap.tap_hold_loader")

local DEFAULTS = require("infra.paths").shared("tap_hold/defaults.toml")

--- Loads the defaults with a user file holding `text`.
local function load(text)
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
	local loaded = Config.load(DEFAULTS, path)
	os.remove(path)
	return loaded
end

helpers.describe("tap-hold config: the user file over the shared defaults", function()

	helpers.it("keeps the shared defaults when the user file is absent", function()
		local loaded = Config.load(DEFAULTS, "/nonexistent/tap_hold.toml")
		helpers.assert_true(loaded.enabled)
		helpers.assert_eq(loaded.keys.left_shift.tap_action, "copy")
		helpers.assert_eq(loaded.keys.caps_lock.hold_modifier, "ctrl")
		helpers.assert_nil(loaded.user_error)
	end)

	helpers.it("changes one field and keeps the others", function()
		local loaded = load('[tap_hold.keys.left_shift]\ntap_action = "paste"\n')
		helpers.assert_eq(loaded.keys.left_shift.tap_action, "paste")
		helpers.assert_eq(loaded.keys.left_shift.hold_modifier, "shift")
		helpers.assert_eq(loaded.keys.left_ctrl.tap_action, "paste", "other keys keep their defaults")
	end)

	helpers.it("drops the default modifier when a layer is chosen, and the reverse", function()
		local loaded = load('[tap_hold.keys.caps_lock]\nhold_layer = "nav"\n[tap_hold.keys.left_alt]\nhold_modifier = "alt"\n')
		helpers.assert_eq(loaded.keys.caps_lock.hold_layer, "nav")
		helpers.assert_nil(loaded.keys.caps_lock.hold_modifier, "CapsLock is the layer, no longer Ctrl")
		helpers.assert_eq(loaded.keys.left_alt.hold_modifier, "alt")
		helpers.assert_nil(loaded.keys.left_alt.hold_layer)
	end)

	helpers.it("lets an empty hold clear the default one", function()
		local loaded = load('[tap_hold.keys.caps_lock]\nhold_modifier = ""\n')
		helpers.assert_eq(loaded.keys.caps_lock.hold_modifier, "")
	end)

	helpers.it("starts from no key when defaults are not inherited", function()
		local loaded = load('[tap_hold]\ninherit_defaults = false\n')
		helpers.assert_nil(next(loaded.keys), "Disable all leaves no tap-hold")
	end)

	helpers.it("reads the feature switch", function()
		helpers.assert_true(not load('[tap_hold]\nenabled = false\n').enabled)
	end)

	helpers.it("falls back to 0.2 s for a threshold out of range", function()
		local loaded = load('[tap_hold.keys.left_shift]\ntime_activation_seconds = 30\n')
		helpers.assert_eq(loaded.keys.left_shift.time_activation_seconds, Config.FALLBACK_THRESHOLD_SECONDS)
	end)

	helpers.it("disables a key with a field of the wrong type", function()
		local loaded = load('[tap_hold.keys.left_shift]\ntap_action = 3\n')
		helpers.assert_eq(loaded.keys.left_shift.enabled, false)
	end)

	helpers.it("reports a malformed user file and keeps the defaults whole", function()
		local loaded = load('[tap_hold.keys.left_shift\ntap_action = "paste"\n')
		helpers.assert_eq(loaded.user_error, "malformed")
		helpers.assert_eq(loaded.keys.left_shift.tap_action, "copy")
	end)

end)
