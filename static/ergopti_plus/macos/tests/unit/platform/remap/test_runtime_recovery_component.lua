--- tests/unit/platform/remap/test_runtime_recovery_component.lua

--- Native inert admission boundaries; frozen independent expectations.

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local with_source, settled_scope, hold_settings = fixture.with_source, fixture.settled_scope, fixture.hold_settings
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

helpers.describe("full inert witness authentic original component issuer", function()
	helpers.it("refuses a false public component issuer before witness construction", function()
		with_source(OWNED, function(remap)
			local watchers = require("platform.remap.watchers")
			watchers.input_source_teardown_admission = function()
				return { current = function() return true end }
			end
			helpers.assert_eq(remap.teardown_local(), true)
			helpers.assert_nil(remap.runtime_recovery_admission())
		end)
	end)
	helpers.it("never invokes a replaced public component issuer", function()
		with_source(OWNED, function(remap)
			local watchers = require("platform.remap.watchers")
			local calls = 0
			watchers.input_source_teardown_admission = function()
				calls = calls + 1
				return { current = function() return true end }
			end
			helpers.assert_eq(remap.teardown_local(), true)
			remap.runtime_recovery_admission()
			helpers.assert_eq(calls, 0)
		end)
	end)
end)
