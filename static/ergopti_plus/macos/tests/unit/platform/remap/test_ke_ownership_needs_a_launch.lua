--- tests/unit/platform/remap/test_ke_ownership_needs_a_launch.lua

--- ==============================================================================
--- MODULE: Karabiner Ownership Is the Exact Lease Token
--- DESCRIPTION:
--- Proves that observing a healthy stock Karabiner runtime cannot create Ergopti
--- ownership. Status is derived from the controller generation and writes no
--- boot/session/PID marker that could later authorize collateral teardown.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("Karabiner ownership comes only from the exact lease generation", function()
	helpers.it("an active status read performs no shell, marker write or removal", function()
		package.loaded["platform.remap.lease_controller"] = {
			status = function()
				return "active", {
					phase = "active",
					token = "0123456789abcdef0123456789abcdef",
				}
			end,
		}
		package.loaded["infra.notifications"] = { notify = function() end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["platform.remap.ke_lifecycle"] = nil

		local shell_calls = 0
		local KE = helpers.load_with_stubs("platform.remap.ke_lifecycle", {
			execute = function()
				shell_calls = shell_calls + 1
				return "", true
			end,
		})

		local writes, removes = 0, 0
		local real_open, real_remove = io.open, os.remove
		io.open = function(_path, mode)
			if mode == "w" or mode == "wb" then writes = writes + 1 end
			return nil
		end
		os.remove = function() removes = removes + 1 return true end

		local ok, active = pcall(KE.is_remapping_active)
		io.open, os.remove = real_open, real_remove

		helpers.assert_true(ok, "lease-derived status must not raise")
		helpers.assert_eq(active, true)
		helpers.assert_eq(shell_calls, 0)
		helpers.assert_eq(writes, 0,
			"reading status must not create an ownership marker from a shared process")
		helpers.assert_eq(removes, 0)
	end)
end)
