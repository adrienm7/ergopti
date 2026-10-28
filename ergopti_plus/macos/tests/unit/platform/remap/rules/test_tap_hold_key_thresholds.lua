--- tests/unit/platform/remap/rules/test_tap_hold_key_thresholds.lua

--- ==============================================================================
--- MODULE: Tap-Hold Delay Model On macOS (no shipped per-key delay)
--- DESCRIPTION:
--- No key ships a delay of its own (PAR-15): every key follows the global delay,
--- the timing registry's tap_hold.default_activation_ms, until the user gives it
--- one. Replays the shipped file, the global default macOS reads, and the
--- per-key override/reset accessors against the real state owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local path = helpers.driver_root() .. "/../_shared/tap_hold/defaults.toml"

--- The shipped defaults, decoded afresh.
local function shipped()
	local handle = assert(io.open(path, "r"))
	local decoded = require("toml_codec").decode(handle:read("*a"))
	assert(handle:close())
	return decoded
end

helpers.describe("tap-hold delay model on macOS (par-15)", function()
	helpers.it("no per-key delay remains in the shipped catalogue", function()
		local keys = shipped().tap_hold.keys
		helpers.assert_true(next(keys) ~= nil, "the catalogue lists keys")
		for key_id, fields in pairs(keys) do
			helpers.assert_nil(fields.time_activation_seconds, key_id .. " must not ship a delay of its own")
		end
		helpers.assert_nil(shipped().hs_timeouts.tap_hold_timeout_ms, "no second declaration of the global")
	end)

	helpers.it("the global default is the timing registry's, the one Windows and Linux read", function()
		local Defaults = require("platform.remap.defaults")
		helpers.assert_eq(Defaults.tap_hold_timeout_ms, require("infra.timings").ms("tap_hold", "default_activation_ms"))
		helpers.assert_nil(Defaults.tap_hold_key_timeouts_ms, "macOS resolves no shipped per-key delay")
	end)

	helpers.it("the retired per-key delays are resolved to the driver's key ids for the migrating drivers", function()
		local Catalog = require("tap_hold.key_catalog")
		local retired = Catalog.retired_delays_for_platform(shipped(), "hs")
		helpers.assert_eq(retired.caps_lock, 0.35)
		helpers.assert_eq(retired.left_control, 0.2, "left_ctrl is left_control in the macOS column")
		helpers.assert_nil(retired.left_alt, "left_alt is a Windows and Linux key")
	end)

	helpers.it("refuses a retired delay that is not a positive number, or for a key the catalogue does not list", function()
		local Catalog = require("tap_hold.key_catalog")
		for _, bad in ipairs({ 0, -0.2, "0.2" }) do
			local defaults = shipped()
			defaults.tap_hold.retired_delays.caps_lock = bad
			helpers.assert_true(not pcall(Catalog.retired_delays_for_platform, defaults, "hs"), "accepted " .. tostring(bad))
		end
		local defaults = shipped()
		defaults.tap_hold.retired_delays.ghost = 0.2
		local ok, err = pcall(Catalog.retired_delays_for_platform, defaults, "hs")
		helpers.assert_true(not ok and tostring(err):find("ghost", 1, true) ~= nil, tostring(err))
	end)
end)
