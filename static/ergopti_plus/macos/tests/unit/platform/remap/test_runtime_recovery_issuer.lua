--- tests/unit/platform/remap/test_runtime_recovery_issuer.lua

--- Native inert admission boundaries; frozen independent expectations.

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local with_source, settled_scope, hold_settings = fixture.with_source, fixture.settled_scope, fixture.hold_settings
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

helpers.describe("inert native consumer issuer origin", function()
	helpers.it("refuses pre-init same-source input-only issuer alias", function()
		with_source(OWNED, function(remap)
			helpers.assert_eq(remap.teardown_local(), true)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end, nil, { input_only_issuer = true })
	end)
end)
