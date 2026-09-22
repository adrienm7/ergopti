--- tests/unit/ui/test_healthcheck_remap_approval.lua

--- ==============================================================================
--- MODULE: Healthcheck reports a remap helper held for Login Items approval
--- DESCRIPTION:
--- The remap engine has no tray row, so the health check is where a support
--- request sees that its helper waits for Login Items approval. The collector
--- reads the lease in memory only, and the plain report says what to do.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the real healthcheck helpers over a lease controller double.
--- @param status_fn function Replacement for LeaseController.status.
--- @return table helpers module
local function load_helpers(status_fn)
	package.loaded["platform.remap.lease_controller"] = { status = status_fn }
	package.loaded["ui.healthcheck.helpers"] = nil
	return helpers.load_with_stubs("ui.healthcheck.helpers")
end

helpers.describe("healthcheck: remap approval state", function()
	helpers.it("reports a helper that requires Login Items approval", function()
		local H = load_helpers(function()
			return "starting", { phase = "starting", guardian_status = "requires_approval" }
		end)
		local st = H.collect_remap_state()
		package.loaded["platform.remap.lease_controller"] = nil
		helpers.assert_eq(st.phase, "starting")
		helpers.assert_eq(st.guardian_status, "requires_approval")
		helpers.assert_eq(st.approval_required, true)
	end)

	helpers.it("reports an approved helper as needing nothing", function()
		local H = load_helpers(function() return "active", { guardian_status = "ready" } end)
		local st = H.collect_remap_state()
		package.loaded["platform.remap.lease_controller"] = nil
		helpers.assert_eq(st.approval_required, false)
		helpers.assert_eq(st.guardian_status, "ready")
	end)

	helpers.it("degrades to unknown when the lease cannot be read", function()
		local H = load_helpers(function() error("not initialised") end)
		local st = H.collect_remap_state()
		package.loaded["platform.remap.lease_controller"] = nil
		helpers.assert_eq(st.phase, "unknown")
		helpers.assert_eq(st.approval_required, false)
	end)

	helpers.it("the plain report tells the user where to approve", function()
		local core = helpers.load_with_stubs("ui.healthcheck.core")
		local text = core.format_plain({
			version = "test", sys = {}, uptime_sec = 1, warn_count = 0, err_count = 0,
			event_tap_timeout_telemetry = { summary = "n/a" },
			remap = { phase = "starting", guardian_status = "requires_approval", approval_required = true },
		})
		helpers.assert_contains(text, "Remap engine     : phase=starting guardian=requires_approval")
		helpers.assert_contains(text, "Login Items")
	end)
end)
