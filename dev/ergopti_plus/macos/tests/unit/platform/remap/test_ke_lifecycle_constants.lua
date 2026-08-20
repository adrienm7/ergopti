--- tests/unit/platform/remap/test_ke_lifecycle_constants.lua

--- ==============================================================================
--- MODULE: Karabiner Lifecycle Safe Public Surface
--- DESCRIPTION:
--- Pins the removal of process-control APIs from the lifecycle facade. The
--- official Karabiner runtime is shared, so no exported kill/reset/headless-start
--- primitive can ever be made safe by an ownership boolean.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["platform.remap.lease_controller"] = {
	status = function() return "idle", { phase = "idle" } end,
}
package.loaded["infra.notifications"] = { notify = function() end }
package.loaded["infra.i18n"] = { get = function(key) return key end }
local KE = helpers.load_with_stubs("platform.remap.ke_lifecycle")





-- ======================================
-- ======================================
-- ======= 1/ Safe Public Surface =======
-- ======================================
-- ======================================

helpers.describe("KELifecycle public surface is non-destructive", function()
	helpers.it("exports lease status, explicit GUI open and onboarding probe", function()
		helpers.assert_eq(type(KE.status), "function")
		helpers.assert_eq(type(KE.is_remapping_active), "function")
		helpers.assert_eq(type(KE.is_grabber_running), "function")
		helpers.assert_eq(type(KE.open_gui), "function")
	end)

	helpers.it("exports no stock-process kill, reset, ownership or auto-start primitive", function()
		for _, name in ipairs({
			"KILL_CMD",
			"KILL_FAST_CMD",
			"kill_async",
			"run_total_reset",
			"run_total_reset_async",
			"is_hs_owned_bridge",
			"launch_headless",
			"prime_ke_for_session",
		}) do
			helpers.assert_eq(KE[name], nil,
				"unsafe lifecycle primitive must stay retired: " .. name)
		end
	end)
end)
