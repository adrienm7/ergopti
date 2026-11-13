--- tests/unit/settings/test_byte_limits.lua

--- ==============================================================================
--- MODULE: Byte Limits Tests (Linux)
--- DESCRIPTION:
--- Registers the shared [limits] contract and pins the two Linux-only readers:
--- the release-list transport cap of the updater, which is the bound of the
--- stored copy, and the network field check, which reads one byte over the
--- shared PAC cap so an oversized PAC is reported as oversized.
--- ==============================================================================

local helpers = require("tests.helpers")
local Timings = require("core.timing.engine.timings")

require("tests.lua.byte_limits_contract").register(helpers, { driver = "linux", timings = Timings })

helpers.describe("Linux [limits] byte caps", function()
	helpers.it("reads the network check body cap one byte over the shared PAC cap", function()
		helpers.assert_eq(Timings.count("limits", "network_check_body_bytes"), 1048577)
		helpers.assert_eq(Timings.count("limits", "network_check_body_bytes"),
			require("core.network.engine.pac_check").MAX_BYTES + 1)
		package.loaded["core.network.adapters.check_ports"] = nil
		helpers.assert_eq(require("core.network.adapters.check_ports").MAX_BODY_BYTES,
			Timings.count("limits", "network_check_body_bytes"))
	end)
end)
