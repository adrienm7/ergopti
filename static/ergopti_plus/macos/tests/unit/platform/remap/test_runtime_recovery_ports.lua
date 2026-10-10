--- tests/unit/platform/remap/test_runtime_recovery_ports.lua

--- Native inert admission boundaries; frozen independent expectations.

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local with_source, settled_scope, hold_settings = fixture.with_source, fixture.settled_scope, fixture.hold_settings
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

helpers.describe("inert recovery exact auxiliary local teardown ports", function()
	for _, spec in ipairs({ { "modules.keylogger.kc_bridge", "clear_managed_set" },
		{ "adapters.hotkey_registrar", "unbind" },
		{ "platform.remap.ke_variables", "clear_recovery_observer" } }) do
		helpers.it("revokes exact auxiliary teardown port swap: " .. spec[1], function()
			with_source(OWNED, function(remap)
				local scope = settled_scope(remap)
				local owner = require(spec[1]); local original = owner[spec[2]]
				owner[spec[2]] = function() return true end
				helpers.assert_eq(scope.current(), false)
				owner[spec[2]] = original; helpers.assert_eq(scope.current(), false)
			end)
		end)
	end
end)
