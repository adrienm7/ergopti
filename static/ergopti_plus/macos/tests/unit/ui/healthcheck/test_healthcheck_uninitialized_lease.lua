--- tests/unit/ui/healthcheck/test_healthcheck_uninitialized_lease.lua

--- ==============================================================================
--- MODULE: Healthcheck before the lease controller init (macOS)
--- DESCRIPTION:
--- A boot that stopped before the Karabiner lease controller's init still
--- collects diagnostics. The input section asked the controller for its status,
--- which logged "'status' called before M.init()" as an ERROR (field session
--- 2026-10-27, after a config migration refusal). The collector now reports the
--- phase as uninitialized without calling status().
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("healthcheck: remapping phase before the lease init", function()
	helpers.it("reports uninitialized without asking an uninitialized controller", function()
		local saved, prior_hs = {}, _G.hs
		for name, value in pairs(package.loaded) do saved[name] = value end
		local status_calls = 0
		local ok, err = xpcall(function()
			helpers.load_with_stubs("infra.logger")
			package.loaded["platform.remap.lease_controller"] = {
				is_initialized = function() return false end,
				status = function()
					status_calls = status_calls + 1
					return "uninitialized", { phase = "uninitialized" }
				end,
			}
			package.loaded["ui.healthcheck.helpers"] = nil
			local input = require("ui.healthcheck.helpers").collect_input()
			helpers.assert_eq(input.remap_phase, "uninitialized")
			helpers.assert_eq(status_calls, 0, "status() before init logs an ERROR, so it is not called")
		end, debug.traceback)
		for name in pairs(package.loaded) do
			if saved[name] == nil then package.loaded[name] = nil end
		end
		for name, value in pairs(saved) do package.loaded[name] = value end
		_G.hs = prior_hs
		if not ok then error(err, 0) end
	end)
end)
