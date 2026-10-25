--- tests/unit/platform/remap/rules/test_tap_hold_key_thresholds.lua

--- ==============================================================================
--- MODULE: Shared Per-Key Tap-Hold Thresholds (macOS ids)
--- DESCRIPTION:
--- The per-key thresholds are declared once, as `time_activation_seconds` under
--- `[tap_hold.keys.<catalogue id>]`; macOS reads them through the catalogue's
--- `hs` column, which reconciles left_ctrl/left_control. Replays the shipped file
--- and the refusals of a malformed one.
--- ==============================================================================

local helpers = require("tests.helpers")
local Catalog = require("tap_hold.key_catalog")
local path = helpers.driver_root() .. "/../_shared/tap_hold/defaults.toml"

--- The shipped defaults, decoded afresh.
local function shipped()
	local handle = assert(io.open(path, "r"))
	local decoded = require("toml_codec").decode(handle:read("*a"))
	assert(handle:close())
	return decoded
end

helpers.describe("shared per-key tap-hold thresholds on macOS (par-15)", function()
	helpers.it("reads the shipped thresholds under the macOS key ids", function()
		helpers.assert_eq(Catalog.thresholds_for_platform(shipped(), "hs"),
			{ caps_lock = 350, left_shift = 350, left_control = 200, tab = 200 })
	end)

	helpers.it("the loader returns the same table as the decoded file", function()
		helpers.assert_eq(Catalog.load_thresholds(path, "hs"), Catalog.thresholds_for_platform(shipped(), "hs"))
	end)

	helpers.it("a key a driver does not have is omitted, not guessed", function()
		local thresholds = Catalog.thresholds_for_platform(shipped(), "hs")
		helpers.assert_nil(thresholds.left_alt, "left_alt is a Windows and Linux key")
		helpers.assert_nil(thresholds.left_option, "left_option declares no threshold")
	end)

	helpers.it("refuses a threshold that is not a positive whole number of milliseconds", function()
		for _, bad in ipairs({ 0, -0.2, 0.2005, "0.2" }) do
			local defaults = shipped()
			defaults.tap_hold.keys.caps_lock.time_activation_seconds = bad
			local ok, err = pcall(Catalog.thresholds_for_platform, defaults, "hs")
			helpers.assert_true(not ok, "accepted " .. tostring(bad))
			helpers.assert_true(tostring(err):find("time_activation_seconds", 1, true) ~= nil, tostring(err))
		end
	end)

	helpers.it("refuses a threshold declared for a key the catalogue does not list", function()
		local defaults = shipped()
		defaults.tap_hold.keys.ghost = { time_activation_seconds = 0.2 }
		local ok, err = pcall(Catalog.thresholds_for_platform, defaults, "hs")
		helpers.assert_true(not ok, "a threshold for an unknown key must be refused")
		helpers.assert_true(tostring(err):find("ghost", 1, true) ~= nil, tostring(err))
	end)
end)
