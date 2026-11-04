--- tests/unit/infra/config/test_byte_limits.lua

--- ==============================================================================
--- MODULE: Byte Limits Tests (Linux)
--- DESCRIPTION:
--- Registers the shared [limits] contract and pins the two Linux-only readers:
--- the release-list transport cap of the updater, which is the bound of the
--- stored copy, and the network field check, which reads one byte over the
--- shared PAC cap so an oversized PAC is reported as oversized.
--- ==============================================================================

local helpers = require("tests.helpers")
local Timings = require("infra.timings")

require("test.byte_limits_contract").register(helpers, { driver = "linux", timings = Timings })

helpers.describe("Linux [limits] byte caps", function()
	helpers.it("reads the network check body cap one byte over the shared PAC cap", function()
		helpers.assert_eq(Timings.count("limits", "network_check_body_bytes"), 1048577)
		helpers.assert_eq(Timings.count("limits", "network_check_body_bytes"),
			require("network.pac_check").MAX_BYTES + 1)
		package.loaded["adapters.network_check_ports"] = nil
		helpers.assert_eq(require("adapters.network_check_ports").MAX_BODY_BYTES,
			Timings.count("limits", "network_check_body_bytes"))
	end)
end)
