--- tests/unit/lib/test_updater_channel_switch.lua

--- ==============================================================================
--- MODULE: updater channel-switch clears cached release (regression)
--- DESCRIPTION:
--- Guards against the regression where start_background_checks() did not clear
--- _cached_release when switching channels. A cached "stable v2.5 available"
--- entry would remain visible in the UI while the "dev" channel was being polled,
--- showing update data from the wrong channel until the first poll completed.
--- Fix: start_background_checks() calls clear_cached_release() after stopping
--- the old timers and before arming the new ones.
--- ==============================================================================

local helpers = require("tests.helpers")

local function fresh_packaged()
	package.loaded["lib.updater"] = nil
	return helpers.load_with_stubs("lib.updater", {
		processInfo = { bundleID = "com.ergopti.app", version = "1.0.0" },
	})
end


-- =====================================================================
-- =====================================================================
-- ======= 1/ Channel switch clears cached release =====================
-- =====================================================================
-- =====================================================================

helpers.describe("updater: channel switch clears cached release", function()

	helpers.it("start_background_checks clears _cached_release before arming new timers", function()
		local upd = fresh_packaged()

		-- Seed a cached release as if a previous stable-channel check completed.
		upd.set_cached_release({ tag = "v2.5.0", url = "https://example.com/v2.5.0" })
		upd.set_update_state("available")
		helpers.assert_true(upd.get_cached_release() ~= nil, "cached release must be set before switch")

		-- Switch to dev channel — the cached release from stable must be cleared.
		upd.start_background_checks("dev", 3600, function() end)
		helpers.assert_true(upd.get_cached_release() == nil,
			"start_background_checks must clear cached release when switching channels")
		helpers.assert_eq(upd.get_update_state(), "idle",
			"update state must reset to idle after channel switch")

		upd.stop_background_checks()
	end)

	helpers.it("source calls clear_cached_release inside start_background_checks", function()
		local src_path = helpers.driver_root() .. "lib/updater.lua"
		local fh = io.open(src_path, "r")
		helpers.assert_true(fh ~= nil, "lib/updater.lua must be readable")
		local src = fh:read("*a"); fh:close()

		local start_pos = src:find("function M%.start_background_checks")
		helpers.assert_true(start_pos ~= nil, "start_background_checks must exist")
		local after_start = src:sub(start_pos)
		-- clear_cached_release must be called inside the function body
		helpers.assert_true(
			after_start:find("clear_cached_release", 1, true) ~= nil,
			"start_background_checks must call clear_cached_release()")
	end)

end)
