--- tests/unit/platform/remap/test_boot_timestamp_memoised.lua

--- ==============================================================================
--- MODULE: Karabiner Status Has No Process-Derived Ownership
--- DESCRIPTION:
--- Replaces the former boot-timestamp owner-marker optimization with the stronger
--- invariant: repeated status reads are pure in-memory lease reads and fork zero
--- subprocesses. A shared process or boot timestamp can never identify Ergopti's
--- rules safely.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner status never consults process or boot identity", function()
	helpers.it("repeated status checks execute zero shell commands", function()
		local calls = 0
		package.loaded["platform.remap.lease_controller"] = {
			status = function() return "active", { phase = "active", token = "abc" } end,
		}
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["platform.remap.ke_lifecycle"] = nil

		local KE = helpers.load_with_stubs("platform.remap.ke_lifecycle", {
			execute = function()
				calls = calls + 1
				return "", true
			end,
		})

		for _ = 1, 5 do
			helpers.assert_eq(KE.is_remapping_active(), true)
		end

		helpers.assert_eq(calls, 0,
			"status must derive from the exact lease token, never sysctl/pgrep/PID ownership")
	end)
end)
