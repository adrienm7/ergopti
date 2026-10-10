--- tests/unit/platform/remap/test_runtime_recovery_onboarding.lua

--- Native inert admission boundaries; frozen independent expectations.

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local with_source, settled_scope, hold_settings = fixture.with_source, fixture.settled_scope, fixture.hold_settings
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

helpers.describe("inert recovery separately loaded installation owner", function()
	helpers.it("refuses an independently loaded onboarding owner after retained teardown", function()
		with_source(OWNED, function(remap)
			local scope = settled_scope(remap)
			package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
			helpers.assert_eq(scope.current(), false)
		end)
	end)
	helpers.it("does not grant authority from a pre-teardown onboarding boolean", function()
		with_source(OWNED, function(remap)
			package.loaded["platform.remap.onboarding"] = { stop = function() return true end }
			helpers.assert_eq(remap.teardown_local(), true)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end)
	end)
end)
