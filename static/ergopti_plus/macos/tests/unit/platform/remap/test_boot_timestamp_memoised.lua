--- tests/unit/platform/remap/test_boot_timestamp_memoised.lua

--- ==============================================================================
--- MODULE: Regression — the boot timestamp is read once, not once per check
--- DESCRIPTION:
--- get_boot_timestamp() forked /usr/sbin/sysctl on every call, and every
--- ownership check and prime-marker check calls it. The value is the machine's
--- boot time: it cannot change while this Lua state exists, so every fork after
--- the first blocked the run loop to re-learn a constant.
---
--- ROOT CAUSE ENCODED:
--- A per-call subprocess for a per-process constant. The test counts sysctl
--- invocations rather than timing them, because the cost is proportional to the
--- fork count and this machine has no macOS runtime to measure on.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("karabiner: the boot timestamp is fetched at most once", function()

	helpers.it("repeated ownership checks fork sysctl only once", function()
		local calls = 0
		local hs_overrides = {
			execute = function(cmd)
				if type(cmd) == "string" and cmd:find("kern.boottime", 1, true) then
					calls = calls + 1
					return "{ sec = 1700000000, usec = 0 }", true
				end
				return "", true
			end,
		}

		package.loaded["platform.remap.ke_lifecycle"] = nil
		local KE = helpers.load_with_stubs("platform.remap.ke_lifecycle", hs_overrides)

		-- Any public entry point that consults the boot session works; call the
		-- ownership predicate several times, which is what the teardown paths do.
		for _ = 1, 5 do pcall(KE.is_hs_owned_bridge) end

		helpers.assert_true(calls <= 1,
			"the boot timestamp cannot change while the process lives, so re-forking sysctl "
			.. "for it on every ownership check is a blocking subprocess spent on a known "
			.. "constant; observed " .. tostring(calls) .. " fork(s)")
	end)

end)
